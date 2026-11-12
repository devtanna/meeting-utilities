import Foundation
import MeetingCore
import Testing
@testable import MeetingAudio

@Suite("Echo from the speakers")
struct EchoTests {
    /// Speech-like audio: noise under a syllable-rate envelope that changes at random, so two tracks only correlate
    /// when one is a copy of the other.
    static func speechLike(seconds: Double, seed: UInt64) -> [Float] {
        var g = SplitMix(seed)
        let n = Int(seconds * 16_000)
        var out = [Float](repeating: 0, count: n)
        var level: Float = 0
        for i in 0..<n {
            if i % 1_600 == 0 { level = g.next() < 0.35 ? 0.002 : 0.05 + 0.15 * g.next() }   // a new "syllable" every 100 ms
            out[i] = level * (2 * g.next() - 1)
        }
        return out
    }

    static func feed(_ m: EchoMonitor, me: [Float], them: [Float]) {
        // 100 ms pieces, as the capture tick delivers them.
        for start in stride(from: 0, to: min(me.count, them.count), by: 1_600) {
            let t = Double(start) / 16_000
            m.append(.system, samples: Array(them[start..<min(start + 1_600, them.count)]), hostTime: t)
            m.append(.microphone, samples: Array(me[start..<min(start + 1_600, me.count)]), hostTime: t)
        }
    }

    @Test func leakedVoiceIsDetected() {
        let them = Self.speechLike(seconds: 60, seed: 1)
        // The mic hears them 120 ms late at a third of the level, plus a little room noise.
        let lag = 1_920
        var g = SplitMix(9)
        let me = (0..<them.count).map { i in (i >= lag ? them[i - lag] * 0.33 : 0) + 0.001 * (2 * g.next() - 1) }
        let m = EchoMonitor(); m.reset(origin: 0)
        Self.feed(m, me: me, them: them)
        #expect(m.echoPresent)
        let moment = m.moment(start: 20, end: 24)
        #expect(moment?.correlated == true && moment?.pure == true)
    }

    @Test func headphonesShowNoEcho() {
        let them = Self.speechLike(seconds: 60, seed: 1), me = Self.speechLike(seconds: 60, seed: 2)
        let m = EchoMonitor(); m.reset(origin: 0)
        Self.feed(m, me: me, them: them)
        #expect(!m.echoPresent)
    }

    @Test func wordsDecideOnlyWithEvidence() {
        let theirs = [EchoText.Line(start: 10, end: 14, text: "We should ship the beta to the first ten customers on Tuesday")]
        let copy = EchoText.Line(start: 10.2, end: 14.1, text: "we should ship the beta to the first ten customers on tuesday")
        let leak = EchoMoment(correlated: true, atLeakLevel: true, pure: true)
        #expect(EchoText.isEcho(mic: copy, theirs: theirs, moment: leak, correlatedAt: true))
        // The person's own words at the same moment are kept.
        #expect(!EchoText.isEcho(mic: .init(start: 10.5, end: 12, text: "Sounds good, I can send the invoice tomorrow"), theirs: theirs, moment: leak, correlatedAt: true))
        // Much louder than the leak: the person talking over them, whatever the words.
        #expect(!EchoText.isEcho(mic: copy, theirs: theirs, moment: EchoMoment(correlated: true, atLeakLevel: false, pure: false), correlatedAt: true))
        // A short reply that repeats their words only goes when the audio echoed right then.
        let short = EchoText.Line(start: 13, end: 14, text: "on Tuesday")
        #expect(!EchoText.isEcho(mic: short, theirs: theirs, moment: EchoMoment(correlated: false, atLeakLevel: true, pure: false), correlatedAt: false))
        // A mic line well after theirs ended is a read-back, not an echo.
        #expect(!EchoText.isEcho(mic: .init(start: 30, end: 34, text: copy.text), theirs: theirs, moment: nil, correlatedAt: false))
    }
}

/// Small deterministic generator for test audio.
struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
    }
}
