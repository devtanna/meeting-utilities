import Foundation
import Testing
@testable import InferenceProtocol
@testable import MeetingAudio

func sine(_ freq: Double, rate: Double, seconds: Double, amp: Float = 0.5) -> [Float] {
    (0..<Int(rate * seconds)).map { amp * Float(sin(2 * .pi * freq * Double($0) / rate)) }
}

@Suite("Audio conversion & queues §13")
struct AudioTests {
    @Test(arguments: [48_000.0, 44_100.0, 16_000.0, 96_000.0, 8_000.0])
    func resamplerRateAndContinuity(_ rate: Double) {
        var r = StreamingResampler(inputRate: rate)
        let input = sine(440, rate: rate, seconds: 2)
        // Feed in irregular buffer sizes; output length must match whole-buffer conversion (state continuity).
        var out: [Float] = []
        var i = 0, sizes = [97, 512, 1, 4096, 333]
        while i < input.count { let n = min(sizes[0], input.count - i); sizes.append(sizes.removeFirst()); out += r.process(Array(input[i..<(i + n)])); i += n }
        #expect(abs(out.count - 32_000) <= 2)
        // No discontinuities: max sample-to-sample delta stays bounded for a 440 Hz tone at 16 kHz.
        let maxDelta = zip(out.dropFirst(100), out.dropFirst(101)).map { abs($0 - $1) }.max() ?? 0
        #expect(maxDelta < 0.12)
    }

    @Test func downmixStereo() {
        let interleaved: [Float] = [1, 0, 0.5, 0.5, -1, 1]
        var out = [Float](repeating: 0, count: 3)
        interleaved.withUnsafeBufferPointer { p in out.withUnsafeMutableBufferPointer { o in Downmix.interleavedToMono(p.baseAddress!, frames: 3, channels: 2, into: o.baseAddress!) } }
        #expect(out == [0.5, 0.5, 0])
    }

    @Test func ringBoundsAndDrops() {
        let ring = SPSCFloatRing(capacity: 1000)
        let data = [Float](repeating: 1, count: 1500)
        data.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 1500, hostTimeSeconds: 10) }
        #expect(ring.availableToRead == 1000)
        #expect(ring.droppedSamples.load(ordering: .relaxed) == 500)
        let (s, t) = ring.drain(maxCount: 400, sampleRate: 100)
        #expect(s.count == 400 && t == 10)
        let (_, t2) = ring.drain(maxCount: 400, sampleRate: 100)
        #expect(abs(t2 - 14) < 1e-9)
    }

    @Test func vadSegmentsSpeechAndBoundsChunks() {
        var c = UtteranceChunker()
        let silence = [Float](repeating: 0.0005, count: 16_000)
        let speech = sine(300, rate: 16_000, seconds: 2, amp: 0.3)
        var out = c.append(silence + speech + silence, hostTime: 100)
        #expect(out.count == 1)
        let u = out[0]
        #expect(abs(u.startHostTime - 100.75) < 0.05) // 250 ms pre-roll before speech at t=101
        #expect(Double(u.samples.count) / 16_000 > 2.0 && Double(u.samples.count) / 16_000 < 2.6)
        // Long monologue: forced 12 s chunks with ≤1 s overlap.
        var c2 = UtteranceChunker()
        out = c2.append(sine(300, rate: 16_000, seconds: 30, amp: 0.3), hostTime: 0)
        #expect(out.count == 2 && out.allSatisfy { $0.forcedSplit && Double($0.samples.count) / 16_000 <= 12.01 })
        #expect(abs(out[1].startHostTime - 11.0) < 0.05)
        #expect(c2.flush() != nil)
    }

    @Test func shortBlipIgnored() {
        var c = UtteranceChunker()
        let blip = sine(300, rate: 16_000, seconds: 0.1, amp: 0.3)
        #expect(c.append([Float](repeating: 0, count: 8000) + blip + [Float](repeating: 0, count: 16_000), hostTime: 0).isEmpty)
    }

    @Test func overlapDedupeOnlyAtSeam() {
        #expect(OverlapDedupe.trimLeadingOverlap(previous: "we should ship it on Monday", next: "on Monday, and then review") == "and then review")
        #expect(OverlapDedupe.trimLeadingOverlap(previous: "yes yes", next: "no really") == "no really")
        // People repeat themselves: identical non-seam phrases survive.
        #expect(OverlapDedupe.trimLeadingOverlap(previous: "thank you", next: "great, thank you") == "great, thank you")
    }

    @Test func budget() {
        let b = AudioBudget(limitBytes: 100)
        b.set("a", bytes: 60); b.set("b", bytes: 50)
        #expect(b.isExceeded && b.peakBytes == 110)
        b.set("b", bytes: 0)
        #expect(!b.isExceeded)
    }

    @Test func chunkHeaderValidation() {
        let h = ChunkHeader(sessionID: UUID(), jobID: UUID(), generation: 1, sequence: 0, source: .microphone, sampleRate: 16_000, frameCount: 16_000, hostTimeStartSeconds: 1, hostTimeEndSeconds: 2)
        #expect(h.validate(pcmByteCount: 64_000) == nil)
        #expect(h.validate(pcmByteCount: 3 * 1024 * 1024) == .size)
        var bad = h; bad.sampleRate = 48_000
        #expect(bad.validate(pcmByteCount: 64_000) == .rate)
        bad = h; bad.protocolVersion = 2
        #expect(bad.validate(pcmByteCount: 64_000) == .version)
        #expect(h.validate(pcmByteCount: 1000) == .frames)
        let samples: [Float] = [0.1, -0.2, 0.3]
        #expect(Wire.samples(Wire.pcmData(samples)) == samples)
    }
}
