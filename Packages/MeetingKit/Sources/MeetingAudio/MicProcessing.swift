import Foundation

// Microphone enhancement chain ported from Meetily (MIT, Zackriya Solutions), `audio_processing.rs` and
// `pipeline.rs`: high-pass (80 Hz) → EBU R128 loudness normalization to -23 LUFS with a 10 ms look-ahead
// peak limiter at -1 dBFS. Meetily keeps RNNoise disabled, so there is no noise suppression step here either.
// Applied to the microphone only; system audio is passed through untouched.

/// First-order IIR high-pass: y[n] = α · (y[n-1] + x[n] - x[n-1]). Removes rumble below the cutoff.
public struct HighPassFilter: Sendable {
    private let alpha: Float
    private var prevInput: Float = 0
    private var prevOutput: Float = 0

    public init(sampleRate: Double, cutoffHz: Double = 80) {
        let rc = 1 / (2 * Double.pi * cutoffHz)
        let dt = 1 / sampleRate
        alpha = Float(rc / (rc + dt))
    }

    public mutating func process(_ samples: inout [Float]) {
        for i in samples.indices {
            let x = samples[i]
            let y = alpha * (prevOutput + x - prevInput)
            prevInput = x
            prevOutput = y
            samples[i] = y
        }
    }
}

/// 10 ms look-ahead limiter: delays the signal and scales any sample above the limit down to it.
struct PeakLimiter: Sendable {
    private var buffer: [Float]
    private var reduction: [Float]
    private var position = 0

    init(sampleRate: Double, lookaheadMs: Double = 10) {
        let n = max(1, Int(sampleRate * lookaheadMs / 1000))
        buffer = Array(repeating: 0, count: n)
        reduction = Array(repeating: 1, count: n)
    }

    mutating func process(_ sample: Float, limit: Float) -> Float {
        buffer[position] = sample
        let a = abs(sample)
        reduction[position] = a > limit ? limit / a : 1
        let out = (position + 1) % buffer.count
        let y = buffer[out] * reduction[out]
        position = out
        return y
    }
}

/// Integrated loudness per ITU-R BS.1770 / EBU R128 (mono): K-weighting, 400 ms blocks with 75 % overlap,
/// absolute gate at -70 LUFS and relative gate at -10 LU. Gated blocks are kept in a 0.1 LU histogram so the
/// integrated value stays O(1) in memory for meetings of any length (the approach libebur128 uses).
struct IntegratedLoudness: Sendable {
    private var shelf: Biquad
    private var highPass: Biquad
    private let hop: Int                       // 100 ms
    private var hopEnergy: Double = 0
    private var hopCount = 0
    private var lastHops: [Double] = []        // energy sums of the last 4 hops
    private var binCount = [Int](repeating: 0, count: 1000)       // -70 … +30 LUFS in 0.1 steps
    private var binEnergy = [Double](repeating: 0, count: 1000)

    init(sampleRate fs: Double) {
        // Pre-filter (high shelf) and RLB high-pass, coefficients for any sample rate (libebur128 derivation).
        var f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                       a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444; q = 0.5003270373238773; g = 0
        k = tan(Double.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        hop = max(1, Int(fs / 10))
    }

    /// Adds samples; returns true when at least one new 400 ms block was measured.
    mutating func add(_ samples: [Float]) -> Bool {
        var updated = false
        for s in samples {
            let y = highPass.process(shelf.process(Double(s)))
            hopEnergy += y * y
            hopCount += 1
            if hopCount == hop {
                lastHops.append(hopEnergy)
                if lastHops.count > 4 { lastHops.removeFirst() }
                hopEnergy = 0; hopCount = 0
                if lastHops.count == 4 {
                    let meanSquare = lastHops.reduce(0, +) / Double(4 * hop)
                    let l = Self.lufs(meanSquare)
                    if l >= -70 {
                        let bin = min(999, max(0, Int((l + 70) * 10)))
                        binCount[bin] += 1
                        binEnergy[bin] += meanSquare
                        updated = true
                    }
                }
            }
        }
        return updated
    }

    /// Gated integrated loudness, or nil before the first block above the absolute gate.
    var integrated: Double? {
        var n = 0, e = 0.0
        for i in 0..<1000 { n += binCount[i]; e += binEnergy[i] }
        guard n > 0 else { return nil }
        let relativeGate = Self.lufs(e / Double(n)) - 10
        let first = min(999, max(0, Int(((relativeGate + 70) * 10).rounded(.up))))
        n = 0; e = 0
        for i in first..<1000 { n += binCount[i]; e += binEnergy[i] }
        guard n > 0 else { return nil }
        return Self.lufs(e / Double(n))
    }

    static func lufs(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(max(meanSquare, 1e-20)) }

    struct Biquad: Sendable {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) { self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2 }
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
}

/// Gain follows the session's cumulative integrated loudness toward -23 LUFS (no cap, as in Meetily), then the
/// limiter keeps peaks under -1 dBFS.
public struct LoudnessNormalizer: Sendable {
    public static let targetLUFS = -23.0
    private var meter: IntegratedLoudness
    private var limiter: PeakLimiter
    private let peakLimit = Float(pow(10, -1.0 / 20))
    public private(set) var gain: Float = 1

    public init(sampleRate: Double) {
        meter = IntegratedLoudness(sampleRate: sampleRate)
        limiter = PeakLimiter(sampleRate: sampleRate)
    }

    public mutating func process(_ samples: inout [Float]) {
        if meter.add(samples), let l = meter.integrated, l.isFinite, l < 0 {
            gain = Float(pow(10, (Self.targetLUFS - l) / 20))
        }
        for i in samples.indices { samples[i] = limiter.process(samples[i] * gain, limit: peakLimit) }
    }
}

/// High-pass → loudness normalization, in Meetily's order.
public struct MicrophoneEnhancer: Sendable {
    private var highPass: HighPassFilter
    private var normalizer: LoudnessNormalizer
    public init(sampleRate: Double) {
        highPass = HighPassFilter(sampleRate: sampleRate, cutoffHz: 80)
        normalizer = LoudnessNormalizer(sampleRate: sampleRate)
    }
    public var gain: Float { normalizer.gain }
    public mutating func process(_ samples: inout [Float]) {
        highPass.process(&samples)
        normalizer.process(&samples)
    }
}
