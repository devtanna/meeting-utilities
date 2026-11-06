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
    public var speech: SpeechParameters
    public init(sessionID: UUID, sources: [CaptureSource], microphoneDeviceUID: String?, speech: SpeechParameters = SpeechParameters()) {
        self.sessionID = sessionID; self.sources = sources; self.microphoneDeviceUID = microphoneDeviceUID; self.speech = speech
    }
}

/// What one source actually delivered during a session; saved with the session so an empty transcript can say why.
public struct SourceStats: Sendable, Codable, Equatable {
    public var device: String = ""
    public var audioSeconds: Double = 0
    /// Loudest 100 ms of the raw signal, before any gain.
    public var peakDB: Float = -120
    public var utterances = 0
    public var restarts = 0
    public var stalls = 0
    public var neuralVAD = false
    public init() {}
}

/// Owns live sources and a 10 Hz processing tick. Per source, following Meetily's pipeline: mono at the device rate
/// → (microphone only) 80 Hz high-pass and loudness normalization → 16 kHz → Silero speech segments.
/// Audio never leaves memory (§13.6).
public final class CaptureController: @unchecked Sendable {
    private struct Pipeline {
        var adapter: any AudioSourceAdapter
        var enhancer: MicrophoneEnhancer?
        var resampler: StreamingResampler
        var chunker: SpeechChunker
        var lastDropped = 0
        var lastDataAt: Double
        var stats = SourceStats()
    }

    /// A running source that delivers nothing for this long is rebuilt.
    static let stallSeconds = 3.0

    private let queue = DispatchQueue(label: "capture.processing", qos: .userInitiated)
    private var pipelines: [CaptureSource: Pipeline] = [:]
    private var finishedStats: [CaptureSource: SourceStats] = [:]
    private var pendingRebuild: Set<CaptureSource> = []
    private var timer: DispatchSourceTimer?
    private var continuation: AsyncStream<CaptureEvent>.Continuation?
    private var configuration: CaptureConfiguration?
    private var deviceObservers: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    public let budget: AudioBudget
    public private(set) var originHostTime: Double = 0

    public init(budget: AudioBudget = AudioBudget()) { self.budget = budget }

    public var isRunning: Bool { queue.sync { timer != nil } }

    /// Starts all requested sources. If any fails, everything started is stopped and the error is thrown,
    /// so the caller can offer an explicitly labelled single-source session instead (§13.3).
    public func start(_ config: CaptureConfiguration) throws -> AsyncStream<CaptureEvent> {
        stop()
        queue.sync { finishedStats = [:]; pendingRebuild = [] }
        let (stream, cont) = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        var started: [CaptureSource: Pipeline] = [:]
        do {
            for source in config.sources {
                do {
                    started[source] = try makePipeline(source, config)
                } catch let e as CaptureSourceError {
                    throw CaptureStartFailure(source: source, error: e)
                }
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
                p.adapter.onDeviceChange = nil
                p.adapter.stop()
                drain(source, &p)
                if let u = p.chunker.flush() { p.stats.utterances += 1; continuation?.yield(.utterance(source, u)) }
                finishedStats[source] = p.stats
                Log.capture.info("capture source \(source.rawValue, privacy: .public) stats audio=\(p.stats.audioSeconds, privacy: .public)s peak=\(p.stats.peakDB, privacy: .public)dB utterances=\(p.stats.utterances, privacy: .public) restarts=\(p.stats.restarts, privacy: .public) stalls=\(p.stats.stalls, privacy: .public) silero=\(p.stats.neuralVAD, privacy: .public)")
            }
            pipelines.removeAll()
            budget.set("rings", bytes: 0)
            continuation?.finish()
            continuation = nil
        }
    }

    /// Per-source stats: live while running, final after stop.
    public func stats() -> [CaptureSource: SourceStats] {
        queue.sync { finishedStats.merging(pipelines.mapValues(\.stats)) { _, live in live } }
    }

    private func makePipeline(_ source: CaptureSource, _ config: CaptureConfiguration) throws -> Pipeline {
        var adapter: any AudioSourceAdapter
        switch source {
        case .microphone:
            let id = config.microphoneDeviceUID.flatMap { AudioDevices.device(uid: $0) }
            adapter = MicrophoneSource(deviceID: id, ringSeconds: 10)
        case .system:
            guard #available(macOS 14.2, *) else { throw CaptureSourceError.tapUnsupported }
            adapter = SystemAudioSource(ringSeconds: 10)
        }
        adapter.onDeviceChange = { [weak self] in self?.scheduleRebuild(source, reason: "device format changed") }
        try adapter.start()
        var p = Pipeline(adapter: adapter, enhancer: source == .microphone ? MicrophoneEnhancer(sampleRate: adapter.nativeSampleRate) : nil,
                         resampler: StreamingResampler(inputRate: adapter.nativeSampleRate), chunker: SpeechChunker.make(config.speech), lastDataAt: HostTime.now())
        p.stats.device = adapter.deviceName
        p.stats.neuralVAD = p.chunker.isNeural
        return p
    }

    private func tick() {
        var ringBytes = 0
        let now = HostTime.now()
        for source in Array(pipelines.keys) {
            guard var p = pipelines[source] else { continue }
            drain(source, &p)
            ringBytes += p.adapter.ring.byteFootprint + p.chunker.bufferedSamples * 4
            pipelines[source] = p
            // Back off (3, 6, 12, 24, 48 s) so a source that never delivers is not rebuilt in a tight loop.
            if now - p.lastDataAt > Self.stallSeconds * Double(1 << min(p.stats.stalls, 4)) {
                pipelines[source]?.stats.stalls += 1
                rebuild(source, reason: "no audio for \(Int(now - p.lastDataAt))s")
            }
        }
        budget.set("rings", bytes: ringBytes)
    }

    private func drain(_ source: CaptureSource, _ p: inout Pipeline) {
        var (raw, t) = p.adapter.ring.drain(maxCount: p.adapter.ring.capacity, sampleRate: p.adapter.nativeSampleRate)
        let dropped = p.adapter.ring.droppedSamples.load(ordering: .relaxed)
        if dropped > p.lastDropped {
            continuation?.yield(.sourceDropped(source, droppedSeconds: Double(dropped - p.lastDropped) / p.adapter.nativeSampleRate, at: t))
            p.lastDropped = dropped
        }
        guard !raw.isEmpty else { return }
        p.lastDataAt = HostTime.now()
        p.stats.audioSeconds += Double(raw.count) / p.adapter.nativeSampleRate
        p.stats.peakDB = max(p.stats.peakDB, Downmix.rmsDBFS(raw[...]))
        p.enhancer?.process(&raw)
        let converted = p.resampler.process(raw)
        continuation?.yield(.level(source, Downmix.rmsDBFS(converted[...])))
        for u in p.chunker.append(converted, hostTime: t - p.resampler.latencySeconds) {
            p.stats.utterances += 1
            continuation?.yield(.utterance(source, u))
        }
    }

    // MARK: Device changes (§13.7): rebuild only the affected source, preserving the session time origin.

    private func observeDevices() {
        deviceObservers = AudioDevices.observeChanges(queue: queue) { [weak self] sel in
            guard let self else { return }
            if sel == kAudioHardwarePropertyDefaultOutputDevice { self.scheduleRebuild(.system, reason: "default output changed") }
            if sel == kAudioHardwarePropertyDefaultInputDevice, self.configuration?.microphoneDeviceUID == nil { self.scheduleRebuild(.microphone, reason: "default input changed") }
            if sel == kAudioHardwarePropertyDevices, let uid = self.configuration?.microphoneDeviceUID, AudioDevices.device(uid: uid) == nil {
                self.continuation?.yield(.sourceFailed(.microphone, .noInputDevice))
            }
        }
    }

    private func removeDeviceObservers() {
        AudioDevices.removeObservers(deviceObservers, queue: queue)
        deviceObservers = []
    }

    /// Device notifications arrive in bursts; rebuild once after they settle.
    private func scheduleRebuild(_ source: CaptureSource, reason: String) {
        queue.async { [weak self] in
            guard let self, self.pipelines[source] != nil, !self.pendingRebuild.contains(source) else { return }
            self.pendingRebuild.insert(source)
            self.queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                guard let self else { return }
                self.pendingRebuild.remove(source)
                self.rebuild(source, reason: reason)
            }
        }
    }

    /// Must run on `queue`.
    private func rebuild(_ source: CaptureSource, reason: String) {
        guard let config = configuration, var p = pipelines[source] else { return }
        Log.capture.info("rebuilding \(source.rawValue, privacy: .public): \(reason, privacy: .public)")
        p.adapter.onDeviceChange = nil
        p.adapter.stop()
        drain(source, &p)
        if let u = p.chunker.flush() { p.stats.utterances += 1; continuation?.yield(.utterance(source, u)) }
        do {
            var next = try makePipeline(source, config)
            let device = next.stats.device
            next.stats = p.stats
            next.stats.device = device
            next.stats.restarts += 1
            pipelines[source] = next
            continuation?.yield(.sourceRestarted(source))
        } catch {
            finishedStats[source] = p.stats
            pipelines.removeValue(forKey: source)
            continuation?.yield(.sourceFailed(source, error as? CaptureSourceError ?? .engineStartFailed("rebuild")))
        }
    }
}

/// Short local source tests used during setup (§13.3). Nothing is written to disk.
public enum SourceTest {
    public struct Result: Sendable { public var peakDB: Float; public var heardSignal: Bool; public var error: CaptureSourceError? }

    public static func run(_ source: CaptureSource, microphoneUID: String?, seconds: Double = 3, during: (@Sendable () -> Void)? = nil) async -> Result {
        let controller = CaptureController()
        let config = CaptureConfiguration(sessionID: UUID(), sources: [source], microphoneDeviceUID: microphoneUID)
        let stream: AsyncStream<CaptureEvent>
        do { stream = try controller.start(config) } catch let e as CaptureStartFailure {
            return Result(peakDB: -120, heardSignal: false, error: e.error)
        } catch { return Result(peakDB: -120, heardSignal: false, error: .engineStartFailed("unknown")) }
        during?()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in stream {} }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                controller.stop()
            }
        }
        // Judge the raw signal: the microphone's normalizer would make any noise look loud.
        let peak = controller.stats()[source]?.peakDB ?? -120
        return Result(peakDB: peak, heardSignal: peak > -50, error: nil)
    }
}
