import Foundation
import Synchronization

/// Lock-free single-producer/single-consumer ring of Float samples with timestamps.
/// The real-time callback only copies into preallocated storage: no allocation, locks, I/O, or logging (§4.3).
public final class SPSCFloatRing: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    /// Count of samples the producer had to drop because the consumer fell behind.
    public let droppedSamples = Atomic<Int>(0)
    /// Host time (seconds) of the most recent write's first sample, and the sample index it corresponds to.
    private let lastStampTime = Atomic<UInt64>(0)
    private let lastStampIndex = Atomic<Int>(0)

    public init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    /// Producer side (real-time safe).
    public func write(_ src: UnsafePointer<Float>, count: Int, hostTimeSeconds: Double) {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacity - (w - r)
        let n = min(count, free)
        if n < count { droppedSamples.add(count - n, ordering: .relaxed) }
        guard n > 0 else { return }
        lastStampTime.store(hostTimeSeconds.bitPattern, ordering: .relaxed)
        lastStampIndex.store(w, ordering: .relaxed)
        let start = w % capacity
        let first = min(n, capacity - start)
        (storage + start).update(from: src, count: first)
        if n > first { storage.update(from: src + first, count: n - first) }
        writeIndex.store(w + n, ordering: .releasing)
    }

    /// Consumer side. Returns samples and the host time of the first returned sample (estimated from the last stamp).
    public func drain(maxCount: Int, sampleRate: Double) -> (samples: [Float], hostTime: Double) {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(w - r, maxCount)
        guard n > 0 else { return ([], 0) }
        var out = [Float](repeating: 0, count: n)
        let start = r % capacity
        let first = min(n, capacity - start)
        out.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.update(from: storage + start, count: first)
            if n > first { (buf.baseAddress! + first).update(from: storage, count: n - first) }
        }
        readIndex.store(r + n, ordering: .releasing)
        let stampTime = Double(bitPattern: lastStampTime.load(ordering: .relaxed))
        let stampIndex = lastStampIndex.load(ordering: .relaxed)
        let t = stampTime + Double(r - stampIndex) / sampleRate
        return (out, t)
    }

    public var availableToRead: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed) }
    public var byteFootprint: Int { capacity * MemoryLayout<Float>.size }
}

/// Second-order low-pass (RBJ cookbook) with persistent state across buffers.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(lowPassCutoff fc: Double, sampleRate fs: Double, q: Double = 0.7071) {
        let w0 = 2 * Double.pi * fc / fs
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        b0 = Float((1 - cosw) / 2 / a0); b1 = Float((1 - cosw) / a0); b2 = b0
        a1 = Float(-2 * cosw / a0); a2 = Float((1 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// Converts mono input at any rate to 16 kHz, keeping filter and phase state across buffers (§13.4).
public struct StreamingResampler: Sendable {
    public let inputRate: Double
    public let outputRate: Double
    private var filters: [Biquad]
    private var phase: Double = 0          // position of next output sample in input-sample units, relative to `prev`
    private var prev: Float = 0
    private var hasPrev = false

    public init(inputRate: Double, outputRate: Double = 16_000) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        if inputRate > outputRate {
            let cutoff = outputRate * 0.45
            filters = [Biquad(lowPassCutoff: cutoff, sampleRate: inputRate), Biquad(lowPassCutoff: cutoff, sampleRate: inputRate)]
        } else {
            filters = []
        }
    }

    /// Group delay introduced by the anti-aliasing filters, in seconds (accounted for in timestamps).
    public var latencySeconds: Double { filters.isEmpty ? 0 : 2 * 0.225 / (outputRate * 0.45) / .pi }

    public mutating func process(_ input: [Float]) -> [Float] {
        if inputRate == outputRate { return input }
        let step = inputRate / outputRate
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / step) + 2)
        for var x in input {
            for i in filters.indices { x = filters[i].process(x) }
            if !hasPrev { prev = x; hasPrev = true; phase = 0; out.append(x); phase += step; continue }
            // Emit all output samples that fall between prev (t=0) and x (t=1).
            phase -= 1
            while phase <= 0 {
                let frac = Float(1 + phase)
                out.append(prev + (x - prev) * frac)
                phase += step
            }
            prev = x
        }
        return out
    }
}

public enum Downmix {
    /// Averages interleaved channels into mono. Like Meetily, only the first two channels of a mic array are used:
    /// extra beam-forming channels can be anti-phase, and averaging them in cancels the voice to near silence.
    public static func interleavedToMono(_ p: UnsafePointer<Float>, frames: Int, channels: Int, into out: UnsafeMutablePointer<Float>) {
        if channels == 1 { out.update(from: p, count: frames); return }
        let used = min(channels, 2)
        let scale = 1 / Float(used)
        for f in 0..<frames {
            var s: Float = 0
            for c in 0..<used { s += p[f * channels + c] }
            out[f] = s * scale
        }
    }

    public static func rmsDBFS(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return -120 }
        var acc: Float = 0
        for s in samples { acc += s * s }
        let rms = (acc / Float(samples.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -120
    }
}

/// One VAD-gated chunk of 16 kHz mono audio.
public struct Utterance: Sendable {
    public var samples: [Float]
    public var startHostTime: Double
    public var endHostTime: Double
    public var forcedSplit: Bool
}

public struct VADParameters: Sendable, Equatable {
    public var preRoll: Double = 0.25
    public var endSilence: Double = 0.6
    public var minimumUtterance: Double = 0.3
    public var maximumChunk: Double = 12
    public var forcedOverlap: Double = 1.0
    public var frameDuration: Double = 0.02
    public var thresholdAboveFloorDB: Float = 9
    public var absoluteFloorDB: Float = -55
    public init() {}
}

/// Energy VAD with adaptive noise floor and bounded chunking (§13.5 initial parameters).
public struct UtteranceChunker: Sendable {
    public let params: VADParameters
    public let sampleRate: Double
    private let frameSize: Int
    private var pending: [Float] = []          // samples not yet framed
    private var pendingStart: Double = 0       // host time of pending[0]
    private var preRoll: [Float] = []
    private var current: [Float] = []
    private var currentStart: Double = 0
    private var inSpeech = false
    private var silenceRun: Double = 0
    private var preRollInCurrent = 0           // samples of pre-roll at the head of `current`
    private var noiseFloor: Float = -60

    public init(params: VADParameters = VADParameters(), sampleRate: Double = 16_000) {
        self.params = params
        self.sampleRate = sampleRate
        frameSize = Int(params.frameDuration * sampleRate)
    }

    public var bufferedSamples: Int { pending.count + preRoll.count + current.count }

    public mutating func append(_ samples: [Float], hostTime: Double) -> [Utterance] {
        if pending.isEmpty { pendingStart = hostTime }
        pending.append(contentsOf: samples)
        var out: [Utterance] = []
        var consumed = 0
        while pending.count - consumed >= frameSize {
            let frame = pending[consumed..<(consumed + frameSize)]
            let t = pendingStart + Double(consumed) / sampleRate
            if let u = processFrame(frame, at: t) { out.append(u) }
            consumed += frameSize
        }
        pending.removeFirst(consumed)
        pendingStart += Double(consumed) / sampleRate
        return out
    }

    /// Flush on stop: emits any in-progress speech above the minimum length.
    public mutating func flush() -> Utterance? {
        defer { current.removeAll(); inSpeech = false; silenceRun = 0; pending.removeAll(); preRoll.removeAll() }
        if inSpeech { current.append(contentsOf: pending) }
        guard inSpeech, Double(current.count - preRollInCurrent) / sampleRate >= params.minimumUtterance else { return nil }
        return Utterance(samples: current, startHostTime: currentStart, endHostTime: currentStart + Double(current.count) / sampleRate, forcedSplit: false)
    }

    private mutating func processFrame(_ frame: ArraySlice<Float>, at t: Double) -> Utterance? {
        let db = Downmix.rmsDBFS(frame)
        let threshold = max(noiseFloor + params.thresholdAboveFloorDB, params.absoluteFloorDB)
        let isSpeech = db > threshold
        if !isSpeech {
            // Track the floor slowly upward, quickly downward.
            noiseFloor = db < noiseFloor ? (noiseFloor * 0.9 + db * 0.1) : (noiseFloor * 0.995 + db * 0.005)
        }
        let preRollMax = Int(params.preRoll * sampleRate)
        if !inSpeech {
            preRoll.append(contentsOf: frame)
            if preRoll.count > preRollMax { preRoll.removeFirst(preRoll.count - preRollMax) }
            if isSpeech {
                inSpeech = true
                silenceRun = 0
                current = preRoll
                preRollInCurrent = preRoll.count
                currentStart = t + params.frameDuration - Double(preRoll.count) / sampleRate
                preRoll.removeAll(keepingCapacity: true)
            }
            return nil
        }
        current.append(contentsOf: frame)
        silenceRun = isSpeech ? 0 : silenceRun + params.frameDuration
        let duration = Double(current.count) / sampleRate
        if silenceRun >= params.endSilence {
            let speechSamples = current.count - Int(silenceRun * sampleRate) + Int(0.1 * sampleRate)
            let u = Utterance(samples: Array(current.prefix(max(0, speechSamples))), startHostTime: currentStart,
                              endHostTime: currentStart + Double(speechSamples) / sampleRate, forcedSplit: false)
            inSpeech = false; current.removeAll(keepingCapacity: true); silenceRun = 0
            // Minimum utterance is measured without the pre-roll context.
            return Double(u.samples.count - preRollInCurrent) / sampleRate >= params.minimumUtterance ? u : nil
        }
        if duration >= params.maximumChunk {
            let u = Utterance(samples: current, startHostTime: currentStart, endHostTime: currentStart + duration, forcedSplit: true)
            let overlap = Int(params.forcedOverlap * sampleRate)
            let keep = Array(current.suffix(overlap))
            currentStart = currentStart + duration - Double(keep.count) / sampleRate
            current = keep
            preRollInCurrent = 0
            return u
        }
        return nil
    }
}

/// Removes words duplicated by the forced-split overlap, only within one source and only at the seam (§13.5).
public enum OverlapDedupe {
    public static func trimLeadingOverlap(previous: String, next: String, maxWords: Int = 6) -> String {
        let prevWords = previous.split(separator: " ").map { normalize($0) }
        let nextWordsRaw = next.split(separator: " ")
        let nextWords = nextWordsRaw.map { normalize($0) }
        guard !prevWords.isEmpty, !nextWords.isEmpty else { return next }
        for k in stride(from: min(maxWords, prevWords.count, nextWords.count), through: 1, by: -1) {
            if Array(prevWords.suffix(k)) == Array(nextWords.prefix(k)) {
                return nextWordsRaw.dropFirst(k).joined(separator: " ")
            }
        }
        return next
    }

    static func normalize(_ s: Substring) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

/// Global PCM/IPC budget accounting: at most 32 MiB including conversion and in-flight chunks (§13.5).
public final class AudioBudget: @unchecked Sendable {
    public static let defaultLimitBytes = 32 * 1024 * 1024
    public let limitBytes: Int
    private let lock = NSLock()
    private var used: [String: Int] = [:]
    public private(set) var peakBytes = 0

    public init(limitBytes: Int = AudioBudget.defaultLimitBytes) { self.limitBytes = limitBytes }

    public func set(_ key: String, bytes: Int) {
        lock.withLock {
            used[key] = bytes
            peakBytes = max(peakBytes, used.values.reduce(0, +))
        }
    }

    public var totalBytes: Int { lock.withLock { used.values.reduce(0, +) } }
    public var isExceeded: Bool { totalBytes > limitBytes }
}
