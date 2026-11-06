import CoreML
import MeetingCore
import Foundation

// Neural voice activity detection, following Meetily's live pipeline (MIT, Zackriya Solutions, `vad.rs`):
// Silero VAD at 16 kHz, speech starts at p ≥ 0.50 and ends after 500 ms below 0.35, with 300 ms pre-speech and
// 400 ms post-speech padding and a 250 ms minimum. The model is Silero VAD v6 (MIT, Silero Team) converted to
// Core ML by FluidInference (MIT); Core ML is a system framework, so no inference runtime is linked into the host.

public enum SileroError: Error { case modelMissing, badOutput }

/// One Silero stream: 512 new samples per call plus the previous 64 as context, LSTM state carried across calls.
public final class SileroVADModel: @unchecked Sendable {
    public static let frameSize = 512
    static let contextSize = 64
    private let model: MLModel
    private let input: MLMultiArray
    private var hidden: MLMultiArray
    private var cell: MLMultiArray

    public init() throws {
        guard let url = Bundle.module.url(forResource: "silero-vad", withExtension: "mlmodelc") else { throw SileroError.modelMissing }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly   // tiny model; CPU keeps per-frame latency steady
        model = try MLModel(contentsOf: url, configuration: config)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.contextSize + Self.frameSize)], dataType: .float32)
        hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
        reset()
    }

    public func reset() {
        for a in [input, hidden, cell] { a.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in p.update(repeating: 0) } }
    }

    /// Speech probability for exactly `frameSize` samples at 16 kHz.
    public func probability(_ frame: ArraySlice<Float>) throws -> Float {
        precondition(frame.count == Self.frameSize)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
            // Context = last 64 samples of the previous frame, which sit at the end of the buffer.
            for i in 0..<Self.contextSize { p[i] = p[Self.frameSize + i] }
            var j = Self.contextSize
            for s in frame { p[j] = s; j += 1 }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["audio_input": input, "hidden_state": hidden, "cell_state": cell])
        let out = try model.prediction(from: features)
        guard let p = out.featureValue(for: "vad_output")?.multiArrayValue, let h = out.featureValue(for: "new_hidden_state")?.multiArrayValue,
              let c = out.featureValue(for: "new_cell_state")?.multiArrayValue else { throw SileroError.badOutput }
        hidden = h; cell = c
        return p[0].floatValue
    }
}

public struct SpeechParameters: Sendable, Equatable {
    public var positiveThreshold: Float = 0.50
    public var negativeThreshold: Float = 0.35
    public var redemption: Double = 0.5
    public var prePad: Double = 0.3
    public var postPad: Double = 0.4
    public var minimumSpeech: Double = 0.25
    /// Live chunks are bounded so the transcript keeps up during long monologues (split with overlap, de-duplicated).
    public var maximumChunk: Double = 12
    public var forcedOverlap: Double = 1.0
    public init() {}
}

/// Turns a 16 kHz stream into speech utterances using Silero.
public struct SileroChunker: @unchecked Sendable {
    public let params: SpeechParameters
    private let model: SileroVADModel
    private let rate = 16_000.0
    private var pending: [Float] = []
    private var pendingStart: Double = 0
    private var preRoll: [Float] = []
    private var current: [Float] = []
    private var currentStart: Double = 0
    private var preRollInCurrent = 0
    private var silenceStart: Int?             // index in `current` where the latest sub-threshold run began
    private var inSpeech = false
    public private(set) var lastProbability: Float = 0

    public init(model: SileroVADModel, params: SpeechParameters = SpeechParameters()) {
        self.model = model
        self.params = params
    }

    public var bufferedSamples: Int { pending.count + preRoll.count + current.count }

    public mutating func append(_ samples: [Float], hostTime: Double) -> [Utterance] {
        if pending.isEmpty { pendingStart = hostTime }
        pending.append(contentsOf: samples)
        let n = SileroVADModel.frameSize
        var out: [Utterance] = []
        var consumed = 0
        while pending.count - consumed >= n {
            let frame = pending[consumed..<(consumed + n)]
            let t = pendingStart + Double(consumed) / rate
            if let u = process(frame, at: t) { out.append(u) }
            consumed += n
        }
        pending.removeFirst(consumed)
        pendingStart += Double(consumed) / rate
        return out
    }

    public mutating func flush() -> Utterance? {
        defer { current.removeAll(); preRoll.removeAll(); pending.removeAll(); inSpeech = false; silenceStart = nil; model.reset() }
        guard inSpeech else { return nil }
        current.append(contentsOf: pending)
        let speechEnd = silenceStart ?? current.count
        guard Double(speechEnd - preRollInCurrent) / rate >= params.minimumSpeech else { return nil }
        let end = min(current.count, speechEnd + Int(params.postPad * rate))
        return Utterance(samples: Array(current.prefix(end)), startHostTime: currentStart, endHostTime: currentStart + Double(end) / rate, forcedSplit: false)
    }

    private mutating func process(_ frame: ArraySlice<Float>, at t: Double) -> Utterance? {
        let p = (try? model.probability(frame)) ?? 0
        lastProbability = p
        let prePadSamples = Int(params.prePad * rate)
        if !inSpeech {
            preRoll.append(contentsOf: frame)
            if preRoll.count > prePadSamples + frame.count { preRoll.removeFirst(preRoll.count - prePadSamples - frame.count) }
            guard p >= params.positiveThreshold else { return nil }
            inSpeech = true
            current = preRoll
            preRollInCurrent = max(0, preRoll.count - frame.count)
            currentStart = t + Double(frame.count) / rate - Double(current.count) / rate
            preRoll.removeAll(keepingCapacity: true)
            silenceStart = nil
            return nil
        }
        current.append(contentsOf: frame)
        if p >= params.positiveThreshold {
            silenceStart = nil
        } else if p < params.negativeThreshold {
            if silenceStart == nil { silenceStart = current.count - frame.count }
            if let s = silenceStart, Double(current.count - s) / rate >= params.redemption {
                let end = min(current.count, s + Int(params.postPad * rate))
                let speech = Double(s - preRollInCurrent) / rate
                let u = Utterance(samples: Array(current.prefix(end)), startHostTime: currentStart,
                                  endHostTime: currentStart + Double(end) / rate, forcedSplit: false)
                // The tail after the post-pad becomes pre-roll for the next utterance.
                preRoll = Array(current.suffix(min(prePadSamples, current.count - end)))
                current.removeAll(keepingCapacity: true)
                inSpeech = false
                silenceStart = nil
                return speech >= params.minimumSpeech ? u : nil
            }
        }
        let duration = Double(current.count) / rate
        if duration >= params.maximumChunk {
            let u = Utterance(samples: current, startHostTime: currentStart, endHostTime: currentStart + duration, forcedSplit: true)
            let keep = Array(current.suffix(Int(params.forcedOverlap * rate)))
            currentStart += duration - Double(keep.count) / rate
            current = keep
            preRollInCurrent = 0
            silenceStart = nil
            return u
        }
        return nil
    }
}

/// Silero when its model loads, otherwise the energy chunker, so capture never fails because of the VAD.
public enum SpeechChunker: @unchecked Sendable {
    case silero(SileroChunker)
    case energy(UtteranceChunker)

    public static func make(_ params: SpeechParameters = SpeechParameters()) -> SpeechChunker {
        if let m = try? SileroVADModel() { return .silero(SileroChunker(model: m, params: params)) }
        Log.capture.error("silero vad unavailable; using energy vad")
        return .energy(UtteranceChunker())
    }

    public var isNeural: Bool { if case .silero = self { true } else { false } }

    public var bufferedSamples: Int {
        switch self { case .silero(let c): c.bufferedSamples; case .energy(let c): c.bufferedSamples }
    }

    public mutating func append(_ samples: [Float], hostTime: Double) -> [Utterance] {
        switch self {
        case .silero(var c): let u = c.append(samples, hostTime: hostTime); self = .silero(c); return u
        case .energy(var c): let u = c.append(samples, hostTime: hostTime); self = .energy(c); return u
        }
    }

    public mutating func flush() -> Utterance? {
        switch self {
        case .silero(var c): let u = c.flush(); self = .silero(c); return u
        case .energy(var c): let u = c.flush(); self = .energy(c); return u
        }
    }
}
