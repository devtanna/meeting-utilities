@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MeetingCore

public enum CaptureEvent: Sendable {
    case utterance(CaptureSource, Utterance)
    case level(CaptureSource, Float)
    case sourceDropped(CaptureSource, droppedSeconds: Double, at: Double)
    case sourceFailed(CaptureSource, CaptureSourceError)
    case sourceRestarted(CaptureSource)
}

/// Identifies which source failed to start so the UI can offer an explicitly labelled single-source session (§13.3).
public struct CaptureStartFailure: Error, Sendable {
    public var source: CaptureSource
    public var error: CaptureSourceError
}

public struct CaptureConfiguration: Sendable {
    public var sessionID: UUID
    public var sources: [CaptureSource]
    public var microphoneDeviceUID: String?
    public var voiceProcessing: Bool
    public var excludeOwnPlayback: Bool
    public var vad: VADParameters
    public init(sessionID: UUID, sources: [CaptureSource], microphoneDeviceUID: String?, voiceProcessing: Bool = false,
                excludeOwnPlayback: Bool = true, vad: VADParameters = VADParameters()) {
        self.sessionID = sessionID; self.sources = sources; self.microphoneDeviceUID = microphoneDeviceUID
        self.voiceProcessing = voiceProcessing; self.excludeOwnPlayback = excludeOwnPlayback; self.vad = vad
    }
}

/// Owns live sources, a 10 Hz processing tick per session, conversion to 16 kHz mono, and VAD chunking.
/// Audio never leaves memory (§13.6).
public final class CaptureController: @unchecked Sendable {
    private struct Pipeline {
        var adapter: any AudioSourceAdapter
        var resampler: StreamingResampler
        var chunker: UtteranceChunker
        var lastDropped = 0
    }

    private let queue = DispatchQueue(label: "capture.processing", qos: .userInitiated)
    private var pipelines: [CaptureSource: Pipeline] = [:]
    private var timer: DispatchSourceTimer?
    private var continuation: AsyncStream<CaptureEvent>.Continuation?
    private var configuration: CaptureConfiguration?
    private var deviceObservers: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var engineObserver: NSObjectProtocol?
    public let budget: AudioBudget
    public private(set) var originHostTime: Double = 0

    public init(budget: AudioBudget = AudioBudget()) { self.budget = budget }

    public var isRunning: Bool { queue.sync { timer != nil } }

    /// Starts all requested sources. If any fails, everything started is stopped and the error is thrown,
    /// so the caller can offer an explicitly labelled single-source session instead (§13.3).
    public func start(_ config: CaptureConfiguration) throws -> AsyncStream<CaptureEvent> {
        stop()
        let (stream, cont) = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        var started: [CaptureSource: Pipeline] = [:]
        do {
            for source in config.sources {
                let adapter: any AudioSourceAdapter
                do {
                    adapter = try makeAdapter(source, config)
                    try adapter.start()
                } catch let e as CaptureSourceError {
                    throw CaptureStartFailure(source: source, error: e)
                }
                started[source] = Pipeline(adapter: adapter, resampler: StreamingResampler(inputRate: adapter.nativeSampleRate),
                                           chunker: UtteranceChunker(params: config.vad))
            }
        } catch {
            for p in started.values { p.adapter.stop() }
            cont.finish()
            throw error
        }
        queue.sync {
            pipelines = started
            continuation = cont
            configuration = config
            originHostTime = HostTime.now()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
        observeDevices()
        Log.capture.info("capture started sources=\(config.sources.count, privacy: .public)")
        return stream
    }

    /// Stops sources in reverse order, flushes in-progress speech, releases buffers.
    public func stop() {
        removeDeviceObservers()
        queue.sync {
            timer?.cancel(); timer = nil
            for source in CaptureSource.allCases.reversed() {
                guard var p = pipelines[source] else { continue }
                p.adapter.stop()
                drain(source, &p)
                if let u = p.chunker.flush() { continuation?.yield(.utterance(source, u)) }
            }
            pipelines.removeAll()
            budget.set("rings", bytes: 0)
            continuation?.finish()
            continuation = nil
        }
    }

    private func makeAdapter(_ source: CaptureSource, _ config: CaptureConfiguration) throws -> any AudioSourceAdapter {
        switch source {
        case .microphone:
            let id = config.microphoneDeviceUID.flatMap { AudioDevices.device(uid: $0) }
            return MicrophoneSource(deviceID: id, voiceProcessing: config.voiceProcessing, ringSeconds: 10)
        case .system:
            if #available(macOS 14.2, *) { return SystemAudioSource(excludeOwnProcess: config.excludeOwnPlayback, ringSeconds: 10) }
            throw CaptureSourceError.tapUnsupported
        }
    }

    private func tick() {
        var ringBytes = 0
        for source in Array(pipelines.keys) {
            guard var p = pipelines[source] else { continue }
            drain(source, &p)
            ringBytes += p.adapter.ring.byteFootprint + p.chunker.bufferedSamples * 4
            pipelines[source] = p
        }
        budget.set("rings", bytes: ringBytes)
    }

    private func drain(_ source: CaptureSource, _ p: inout Pipeline) {
        let (raw, t) = p.adapter.ring.drain(maxCount: p.adapter.ring.capacity, sampleRate: p.adapter.nativeSampleRate)
        let dropped = p.adapter.ring.droppedSamples.load(ordering: .relaxed)
        if dropped > p.lastDropped {
            continuation?.yield(.sourceDropped(source, droppedSeconds: Double(dropped - p.lastDropped) / p.adapter.nativeSampleRate, at: t))
            p.lastDropped = dropped
        }
        guard !raw.isEmpty else { return }
        let converted = p.resampler.process(raw)
        continuation?.yield(.level(source, Downmix.rmsDBFS(converted[...])))
        for u in p.chunker.append(converted, hostTime: t - p.resampler.latencySeconds) {
            continuation?.yield(.utterance(source, u))
        }
    }

    // MARK: Device changes (§13.7): rebuild only the affected source, preserving the session time origin.

    private func observeDevices() {
        deviceObservers = AudioDevices.observeChanges(queue: queue) { [weak self] sel in
            guard let self else { return }
            if sel == kAudioHardwarePropertyDefaultOutputDevice { self.rebuild(.system) }
            if sel == kAudioHardwarePropertyDefaultInputDevice, self.configuration?.microphoneDeviceUID == nil { self.rebuild(.microphone) }
            if sel == kAudioHardwarePropertyDevices, let uid = self.configuration?.microphoneDeviceUID, AudioDevices.device(uid: uid) == nil {
                self.continuation?.yield(.sourceFailed(.microphone, .noInputDevice))
            }
        }
        if let mic = queue.sync(execute: { pipelines[.microphone]?.adapter as? MicrophoneSource }) {
            engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: mic.configurationChangeNotificationObject, queue: nil) { [weak self] _ in
                self?.queue.async { self?.rebuild(.microphone) }
            }
        }
    }

    private func removeDeviceObservers() {
        AudioDevices.removeObservers(deviceObservers, queue: queue)
        deviceObservers = []
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
    }

    /// Must run on `queue`.
    private func rebuild(_ source: CaptureSource) {
        guard let config = configuration, var p = pipelines[source] else { return }
        p.adapter.stop()
        drain(source, &p)
        if let u = p.chunker.flush() { continuation?.yield(.utterance(source, u)) }
        do {
            let adapter = try makeAdapter(source, config)
            try adapter.start()
            pipelines[source] = Pipeline(adapter: adapter, resampler: StreamingResampler(inputRate: adapter.nativeSampleRate), chunker: UtteranceChunker(params: config.vad))
            continuation?.yield(.sourceRestarted(source))
            Log.capture.info("capture source rebuilt \(source.rawValue, privacy: .public)")
        } catch let e as CaptureSourceError {
            pipelines.removeValue(forKey: source)
            continuation?.yield(.sourceFailed(source, e))
        } catch {
            pipelines.removeValue(forKey: source)
            continuation?.yield(.sourceFailed(source, .engineStartFailed("rebuild")))
        }
    }
}

/// Short local source tests used during setup (§13.3). Nothing is written to disk.
public enum SourceTest {
    public struct Result: Sendable { public var peakDB: Float; public var heardSignal: Bool; public var error: CaptureSourceError? }

    public static func run(_ source: CaptureSource, microphoneUID: String?, seconds: Double = 3, excludeOwnPlayback: Bool,
                           during: (@Sendable () -> Void)? = nil) async -> Result {
        let controller = CaptureController()
        let config = CaptureConfiguration(sessionID: UUID(), sources: [source], microphoneDeviceUID: microphoneUID, excludeOwnPlayback: excludeOwnPlayback)
        let stream: AsyncStream<CaptureEvent>
        do { stream = try controller.start(config) } catch let e as CaptureStartFailure {
            return Result(peakDB: -120, heardSignal: false, error: e.error)
        } catch { return Result(peakDB: -120, heardSignal: false, error: .engineStartFailed("unknown")) }
        during?()
        let peak = await withTaskGroup(of: Float?.self) { group -> Float in
            group.addTask {
                var peak: Float = -120
                for await e in stream { if case .level(_, let db) = e { peak = max(peak, db) } }
                return peak
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                controller.stop()
                return nil
            }
            var result: Float = -120
            for await v in group { if let v { result = v } }
            return result
        }
        return Result(peakDB: peak, heardSignal: peak > -50, error: nil)
    }
}
