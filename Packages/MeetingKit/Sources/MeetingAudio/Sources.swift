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
    /// Called (on a Core Audio thread) when the device's sample rate or availability changes; the owner rebuilds.
    var onDeviceChange: (@Sendable () -> Void)? { get set }
    func start() throws
    func stop()
}

public enum HostTime {
    public static func seconds(_ hostTime: UInt64) -> Double { AVAudioTime.seconds(forHostTime: hostTime) }
    public static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

/// Listens to one property of one audio object until removed.
final class PropertyListener: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue = DispatchQueue(label: "capture.device.listener")

    init?(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ handler: @escaping @Sendable () -> Void) {
        self.object = object
        address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
    }

    func remove() { AudioObjectRemovePropertyListenerBlock(object, &address, queue, block) }
}

// MARK: - Microphone (Core Audio HAL input unit on the chosen device)

/// Opens the selected input device directly with its own format and rate, as cpal (Meetily's backend) does on macOS.
/// No AVAudioEngine: its implicit output node and configuration-change resets were stopping capture when a meeting
/// app reconfigured the same microphone.
public final class MicrophoneSource: AudioSourceAdapter, @unchecked Sendable {
    public let kind = CaptureSource.microphone
    public let ring: SPSCFloatRing
    public private(set) var nativeSampleRate: Double = 48_000
    public private(set) var deviceName = "Default microphone"
    public var onDeviceChange: (@Sendable () -> Void)?
    private let requestedDevice: AudioDeviceID?
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var unit: AudioUnit?
    private var channels = 1
    private static let maxFrames = 16_384
    private var buffers: UnsafeMutableAudioBufferListPointer?
    private let scratch: UnsafeMutablePointer<Float>
    private var listeners: [PropertyListener] = []

    /// - Parameter deviceID: nil uses the system default input. Never alters the system default (§13.1).
    public init(deviceID: AudioDeviceID?, ringSeconds: Double = 60) {
        requestedDevice = deviceID
        ring = SPSCFloatRing(capacity: Int(48_000 * ringSeconds))
        scratch = .allocate(capacity: Self.maxFrames)
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    public static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    public static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    public func start() throws {
        guard Self.authorization == .authorized else { throw CaptureSourceError.microphoneDenied }
        device = requestedDevice ?? AudioDevices.defaultInput()
        guard device != kAudioObjectUnknown, AudioDevices.channelCount(device, scope: kAudioObjectPropertyScopeInput) > 0 else { throw CaptureSourceError.noInputDevice }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw CaptureSourceError.engineStartFailed("no_hal_unit") }
        var au: AudioUnit?
        var err = AudioComponentInstanceNew(component, &au)
        guard err == noErr, let au else { throw CaptureSourceError.engineStartFailed("instance_\(err)") }
        unit = au
        do {
            var on: UInt32 = 1, off: UInt32 = 0
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4), "enable_input")
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4), "disable_output")
            var dev = device
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "select_device")
            // The HAL input unit cannot convert sample rates, so the client side uses the device's own rate.
            var hw = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "device_format")
            let rate = AudioDevices.nominalSampleRate(device) ?? hw.mSampleRate
            guard rate > 0, hw.mChannelsPerFrame > 0 else { throw CaptureSourceError.formatUnavailable }
            nativeSampleRate = rate
            channels = Int(hw.mChannelsPerFrame)
            var client = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                     mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                     mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                     mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "client_format")
            var maxFrames = UInt32(Self.maxFrames)
            AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)
            let list = AudioBufferList.allocate(maximumBuffers: channels)
            for i in 0..<channels {
                list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(Self.maxFrames * 4), mData: UnsafeMutableRawPointer.allocate(byteCount: Self.maxFrames * 4, alignment: 16))
            }
            buffers = list
            var callback = AURenderCallbackStruct(inputProc: microphoneInputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input_callback")
            try check(AudioUnitInitialize(au), "initialize")
            err = AudioOutputUnitStart(au)
            try check(err, "start")
        } catch {
            stop()
            throw error
        }
        deviceName = AudioDevices.name(of: device) ?? "Microphone"
        // A meeting app opening the same mic may change its rate; the HAL unit then stops delivering, so rebuild.
        let notify: @Sendable () -> Void = { [weak self] in self?.onDeviceChange?() }
        listeners = [
            PropertyListener(object: device, selector: kAudioDevicePropertyNominalSampleRate, notify),
            PropertyListener(object: device, selector: kAudioDevicePropertyDeviceIsAlive, notify),
        ].compactMap { $0 }
        Log.capture.info("microphone started device=\(self.deviceName, privacy: .public) rate=\(self.nativeSampleRate, privacy: .public) channels=\(self.channels, privacy: .public)")
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw CaptureSourceError.engineStartFailed("\(step)_\(status)") }
    }

    /// Real-time thread: pull the frames, average the first two channels, hand them to the ring.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let unit, let buffers, Int(frames) <= Self.maxFrames else { return noErr }
        for i in 0..<buffers.count { buffers[i].mDataByteSize = frames * 4 }
        let status = AudioUnitRender(unit, flags, time, 1, frames, buffers.unsafeMutablePointer)
        guard status == noErr else { return status }
        let n = Int(frames)
        let used = min(channels, 2)
        guard let first = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        if used == 1 {
            scratch.update(from: first, count: n)
        } else if let second = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            for f in 0..<n { scratch[f] = (first[f] + second[f]) * 0.5 }
        }
        ring.write(scratch, count: n, hostTimeSeconds: HostTime.seconds(time.pointee.mHostTime))
        return noErr
    }

    public func stop() {
        listeners.forEach { $0.remove() }
        listeners = []
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        if let buffers {
            for b in buffers { b.mData?.deallocate() }
            free(buffers.unsafeMutablePointer)
        }
        buffers = nil
    }
}

private func microphoneInputCallback(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                     _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                                     _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<MicrophoneSource>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, frames)
}

// MARK: - System output (Core Audio process tap + private aggregate device)

/// Meetily's configuration: a mono global tap that excludes no process, inside a private aggregate whose clock is
/// the current output device. The output device is NOT added as a sub-device (that captured audio twice).
@available(macOS 14.2, *)
public final class SystemAudioSource: AudioSourceAdapter, @unchecked Sendable {
    public let kind = CaptureSource.system
    public let ring: SPSCFloatRing
    public private(set) var nativeSampleRate: Double = 48_000
    public private(set) var deviceName = "System output"
    public var onDeviceChange: (@Sendable () -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 32_768
    private let ioQueue = DispatchQueue(label: "capture.system.io", qos: .userInteractive)
    private var listeners: [PropertyListener] = []

    public init(ringSeconds: Double = 60) {
        ring = SPSCFloatRing(capacity: Int(48_000 * ringSeconds))
        scratch = .allocate(capacity: scratchCapacity)
    }

    deinit {
        cleanup()
        scratch.deallocate()
    }

    public func start() throws {
        let output = AudioDevices.defaultOutput()
        guard output != kAudioObjectUnknown, let outputUID = AudioDevices.uid(of: output) else { throw CaptureSourceError.formatUnavailable }
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "MeetingUtility system capture"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { throw CaptureSourceError.tapCreateFailed(err) }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, asbd.mSampleRate > 0 else { cleanup(); throw CaptureSourceError.formatUnavailable }

        let dict: [String: Any] = [
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceNameKey: "MeetingUtility Capture",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceUIDKey: "com.devtanna.meetingutils.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard err == noErr else { cleanup(); throw CaptureSourceError.aggregateCreateFailed(err) }
        aggregateID = agg
        deviceName = AudioDevices.name(of: output) ?? "System output"

        let ring = self.ring, scratch = self.scratch, cap = scratchCapacity
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inInputData, inInputTime, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let buf = abl.first, let data = buf.mData else { return }
            let ch = max(1, Int(buf.mNumberChannels))
            let frames = min(Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch), cap)
            guard frames > 0 else { return }
            Downmix.interleavedToMono(data.assumingMemoryBound(to: Float.self), frames: frames, channels: ch, into: scratch)
            ring.write(scratch, count: frames, hostTimeSeconds: HostTime.seconds(inInputTime.pointee.mHostTime))
        }
        guard err == noErr, let procID else { cleanup(); throw CaptureSourceError.ioProcFailed(err) }
        ioProcID = procID
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { cleanup(); throw CaptureSourceError.startFailed(err) }
        // The aggregate runs at the output device's rate; follow it rather than the tap's initial report.
        nativeSampleRate = AudioDevices.nominalSampleRate(aggregateID) ?? asbd.mSampleRate
        let notify: @Sendable () -> Void = { [weak self] in self?.onDeviceChange?() }
        listeners = [PropertyListener(object: aggregateID, selector: kAudioDevicePropertyNominalSampleRate, notify)].compactMap { $0 }
        Log.capture.info("system audio started output=\(self.deviceName, privacy: .public) rate=\(self.nativeSampleRate, privacy: .public) tapRate=\(asbd.mSampleRate, privacy: .public) tapChannels=\(asbd.mChannelsPerFrame, privacy: .public)")
    }

    public func stop() { cleanup() }

    /// Reverse-order cleanup on success, partial failure, stop, and device change (§13.2).
    private func cleanup() {
        listeners.forEach { $0.remove() }
        listeners = []
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

    public static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr && rate > 0 ? rate : nil
    }
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
