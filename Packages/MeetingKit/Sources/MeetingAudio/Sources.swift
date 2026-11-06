@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import MeetingCore

public enum CaptureSourceError: Error, Sendable, Equatable {
    case microphoneDenied
    case noInputDevice
    case engineStartFailed(String)
    case tapUnsupported
    case tapCreateFailed(Int32)
    case aggregateCreateFailed(Int32)
    case ioProcFailed(Int32)
    case startFailed(Int32)
    case formatUnavailable
}

/// A capture source writes mono Float32 at its native rate into a ring buffer from its I/O callback.
public protocol AudioSourceAdapter: AnyObject, Sendable {
    var kind: CaptureSource { get }
    var ring: SPSCFloatRing { get }
    var nativeSampleRate: Double { get }
    var deviceName: String { get }
    func start() throws
    func stop()
}

public enum HostTime {
    public static func seconds(_ hostTime: UInt64) -> Double { AVAudioTime.seconds(forHostTime: hostTime) }
    public static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

// MARK: - Microphone (AVAudioEngine)

public final class MicrophoneSource: AudioSourceAdapter, @unchecked Sendable {
    public let kind = CaptureSource.microphone
    public let ring: SPSCFloatRing
    public private(set) var nativeSampleRate: Double = 48_000
    public private(set) var deviceName = "Default microphone"
    private let engine = AVAudioEngine()
    private let deviceID: AudioDeviceID?
    private var scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 16_384
    private let voiceProcessing: Bool

    /// - Parameter deviceID: nil uses the system default input. Never alters the system default (§13.1).
    public init(deviceID: AudioDeviceID?, voiceProcessing: Bool = false, ringSeconds: Double = 60) {
        self.deviceID = deviceID
        self.voiceProcessing = voiceProcessing
        ring = SPSCFloatRing(capacity: Int(48_000 * ringSeconds))
        scratch = .allocate(capacity: scratchCapacity)
    }

    deinit { scratch.deallocate() }

    public static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    public static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    public func start() throws {
        guard Self.authorization == .authorized else { throw CaptureSourceError.microphoneDenied }
        let input = engine.inputNode
        if let deviceID, let unit = input.audioUnit {
            var id = deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { throw CaptureSourceError.engineStartFailed("select_device_\(status)") }
        }
        if voiceProcessing { try? input.setVoiceProcessingEnabled(true) }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureSourceError.noInputDevice }
        nativeSampleRate = format.sampleRate
        deviceName = AudioDevices.name(of: deviceID ?? AudioDevices.defaultInput()) ?? "Microphone"
        // Monitoring is never enabled: the input node is not connected to the output (§13.1).
        let ring = self.ring, scratch = self.scratch, cap = scratchCapacity
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            guard let ch = buffer.floatChannelData else { return }
            let frames = min(Int(buffer.frameLength), cap)
            let channels = Int(buffer.format.channelCount)
            if channels == 1 || buffer.format.isInterleaved == false {
                if channels == 1 {
                    ring.write(ch[0], count: frames, hostTimeSeconds: HostTime.seconds(time.hostTime))
                    return
                }
                let scale = 1 / Float(channels)
                for f in 0..<frames {
                    var s: Float = 0
                    for c in 0..<channels { s += ch[c][f] }
                    scratch[f] = s * scale
                }
            } else {
                Downmix.interleavedToMono(ch[0], frames: frames, channels: channels, into: scratch)
            }
            ring.write(scratch, count: frames, hostTimeSeconds: HostTime.seconds(time.hostTime))
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw CaptureSourceError.engineStartFailed(String(describing: type(of: error)))
        }
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }

    /// AVAudioEngine posts this when the input route/format changes.
    public var configurationChangeNotificationObject: AnyObject { engine }
}

// MARK: - System output (Core Audio process tap + private aggregate device)

@available(macOS 14.2, *)
public final class SystemAudioSource: AudioSourceAdapter, @unchecked Sendable {
    public let kind = CaptureSource.system
    public let ring: SPSCFloatRing
    public private(set) var nativeSampleRate: Double = 48_000
    public private(set) var deviceName = "System output"
    private let excludeOwnProcess: Bool
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapChannels = 2
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 32_768
    private let ioQueue = DispatchQueue(label: "capture.system.io", qos: .userInteractive)

    public init(excludeOwnProcess: Bool = true, ringSeconds: Double = 60) {
        self.excludeOwnProcess = excludeOwnProcess
        ring = SPSCFloatRing(capacity: Int(48_000 * ringSeconds))
        scratch = .allocate(capacity: scratchCapacity)
    }

    deinit { scratch.deallocate() }

    public func start() throws {
        do {
            try start(clockFromOutputDevice: false)
        } catch {
            // Some configurations need a real device clock: retry with the output device as main sub-device.
            // Its input streams (if any) are never read; only the tap's buffers are consumed.
            cleanup()
            try start(clockFromOutputDevice: true)
        }
    }

    private func start(clockFromOutputDevice: Bool) throws {
        var excluded: [AudioObjectID] = []
        if excludeOwnProcess, let own = AudioDevices.processObject(pid: getpid()) { excluded.append(own) }
        // Global stereo tap of all output except this app's playback (§13.1). Muting stays off: playback is unaffected.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()
        desc.name = "MeetingUtility system capture"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { throw CaptureSourceError.tapCreateFailed(err) }
        tapID = tap

        // Use the tap's reported format; never assume rate/channels (§13.2).
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, asbd.mSampleRate > 0 else { cleanup(); throw CaptureSourceError.formatUnavailable }
        nativeSampleRate = asbd.mSampleRate
        tapChannels = max(1, Int(asbd.mChannelsPerFrame))
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        // Tap-only private aggregate: the physical output device is NOT added as a capture input, which avoids
        // duplicate system audio (Meetily regression, §13.2).
        let aggregateUID = "com.devtanna.meetingutils.aggregate.\(UUID().uuidString)"
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingUtility Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        if clockFromOutputDevice, let outUID = AudioDevices.uid(of: AudioDevices.defaultOutput()) {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outUID]]
        }
        let outputInputChannels = clockFromOutputDevice ? AudioDevices.channelCount(AudioDevices.defaultOutput(), scope: kAudioObjectPropertyScopeInput) : 0
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard err == noErr else { cleanup(); throw CaptureSourceError.aggregateCreateFailed(err) }
        aggregateID = agg
        deviceName = AudioDevices.name(of: AudioDevices.defaultOutput()) ?? "System output"

        let ring = self.ring, scratch = self.scratch, cap = scratchCapacity, channels = tapChannels
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inInputData, inInputTime, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard abl.count > 0 else { return }
            let t = HostTime.seconds(inInputTime.pointee.mHostTime)
            if interleaved {
                // Read only the tap's buffer: skip any buffers contributed by the output device's own input streams.
                var skip = outputInputChannels
                var tapBuffer: AudioBuffer?
                for b in abl {
                    if skip > 0 { skip -= Int(b.mNumberChannels); continue }
                    tapBuffer = b; break
                }
                guard let buf = tapBuffer ?? abl.last, let data = buf.mData else { return }
                let ch = max(1, Int(buf.mNumberChannels))
                let frames = min(Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch), cap)
                Downmix.interleavedToMono(data.assumingMemoryBound(to: Float.self), frames: frames, channels: ch, into: scratch)
                ring.write(scratch, count: frames, hostTimeSeconds: t)
            } else {
                let bufs = Array(abl.suffix(channels))
                guard let first = bufs.first, first.mData != nil else { return }
                let frames = min(Int(first.mDataByteSize) / MemoryLayout<Float>.size, cap)
                let scale = 1 / Float(bufs.count)
                for f in 0..<frames {
                    var s: Float = 0
                    for b in bufs { s += b.mData!.assumingMemoryBound(to: Float.self)[f] }
                    scratch[f] = s * scale
                }
                ring.write(scratch, count: frames, hostTimeSeconds: t)
            }
        }
        guard err == noErr, let procID else { cleanup(); throw CaptureSourceError.ioProcFailed(err) }
        ioProcID = procID
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { cleanup(); throw CaptureSourceError.startFailed(err) }
    }

    public func stop() { cleanup() }

    /// Reverse-order cleanup on success, partial failure, stop, and device change (§13.2).
    private func cleanup() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: - Device helpers

public struct AudioDeviceInfo: Sendable, Hashable, Identifiable {
    public var id: AudioDeviceID
    public var name: String
    public var uid: String
    public var hasInput: Bool
    public var hasOutput: Bool
}

public enum AudioDevices {
    static func address(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    public static func defaultInput() -> AudioDeviceID { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    public static func defaultOutput() -> AudioDeviceID { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    static func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(sel)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    public static func name(of id: AudioDeviceID) -> String? { stringProperty(id, kAudioObjectPropertyName) }
    public static func uid(of id: AudioDeviceID) -> String? { stringProperty(id, kAudioDevicePropertyDeviceUID) }

    static func stringProperty(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        guard err == noErr, let v = value?.takeRetainedValue() else { return nil }
        return v as String
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func all() -> [AudioDeviceInfo] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let name = name(of: id), let uid = uid(of: id), !uid.hasPrefix("com.devtanna.meetingutils"), !uid.hasPrefix("dev.local.meetingutility") else { return nil }
            return AudioDeviceInfo(id: id, name: name, uid: uid, hasInput: channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
                                   hasOutput: channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0)
        }
    }

    public static func device(uid: String) -> AudioDeviceID? { all().first { $0.uid == uid }?.id }

    public static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return err == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    /// Observe default input/output and device-list changes (§13.7). Returns a token to remove.
    public static func observeChanges(queue: DispatchQueue, _ handler: @escaping @Sendable (AudioObjectPropertySelector) -> Void) -> [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] {
        var tokens: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = address(sel)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler(sel) }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            tokens.append((addr, block))
        }
        return tokens
    }

    public static func removeObservers(_ tokens: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)], queue: DispatchQueue) {
        for (a, b) in tokens {
            var addr = a
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, b)
        }
    }
}
