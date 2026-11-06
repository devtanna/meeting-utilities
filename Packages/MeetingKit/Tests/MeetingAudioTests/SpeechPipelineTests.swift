import AVFoundation
import Foundation
import Testing
@testable import MeetingAudio

/// Synthesized speech from the system voice, converted to mono Float32 at `rate`. The temporary file is deleted
/// immediately (the repository and app never keep audio files). Nil when `say` is unavailable.
func spokenPhrase(_ text: String, rate: Double) -> [Float]? {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-tts-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let aiff = dir.appendingPathComponent("p.aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", aiff.path, text]
    guard (try? say.run()) != nil else { return nil }
    say.waitUntilExit()
    guard say.terminationStatus == 0, let file = try? AVAudioFile(forReading: aiff),
          let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: file.processingFormat, to: target),
          let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: input)) != nil,
          let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 1024)
    else { return nil }
    var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return input
    }
    guard error == nil, let ch = output.floatChannelData else { return nil }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(output.frameLength)))
}

func feed(_ chunker: inout SileroChunker, _ samples: [Float], step: Int = 1_600) -> [Utterance] {
    var out: [Utterance] = []
    var i = 0
    while i < samples.count {
        let n = min(step, samples.count - i)
        out += chunker.append(Array(samples[i..<(i + n)]), hostTime: Double(i) / 16_000)
        i += n
    }
    if let u = chunker.flush() { out.append(u) }
    return out
}

@Suite("Meetily-style speech pipeline")
struct SpeechPipelineTests {
    @Test func sileroModelLoadsAndScoresSilenceLow() throws {
        let m = try SileroVADModel()
        let p = try m.probability([Float](repeating: 0, count: SileroVADModel.frameSize)[...])
        #expect(p < 0.2)
    }

    @Test func sileroFindsSpokenPhrase() throws {
        let speech = try #require(spokenPhrase("Testing, hello. Can you hear me?", rate: 16_000))
        var c = SileroChunker(model: try SileroVADModel())
        let silence = [Float](repeating: 0, count: 16_000)
        let out = feed(&c, silence + speech + silence + silence)
        #expect(out.count >= 1)
        let seconds = out.reduce(0) { $0 + Double($1.samples.count) } / 16_000
        #expect(seconds > Double(speech.count) / 16_000 * 0.6)
        // Starts near the speech onset (1 s), allowing the 300 ms pre-pad.
        #expect(out[0].startHostTime > 0.5 && out[0].startHostTime < 1.3)
    }

    @Test func sileroIgnoresNoiseAndTones() throws {
        var c = SileroChunker(model: try SileroVADModel())
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<(16_000 * 3)).map { _ in Float.random(in: -0.01...0.01, using: &rng) }
        #expect(feed(&c, noise).isEmpty)
    }

    @Test func normalizerBringsQuietSpeechToTarget() throws {
        let speech = try #require(spokenPhrase("This is a quiet microphone that still needs to be transcribed correctly.", rate: 48_000))
        var quiet = speech.map { $0 * 0.02 }    // about -34 dB below the synthesized level
        var n = LoudnessNormalizer(sampleRate: 48_000)
        n.process(&quiet)
        n.process(&quiet)   // a second pass measures the already-converged gain
        var meter = IntegratedLoudness(sampleRate: 48_000)
        _ = meter.add(quiet)
        let l = meter.integrated ?? -100
        #expect(abs(l - LoudnessNormalizer.targetLUFS) < 3)
        #expect(quiet.allSatisfy { abs($0) <= 0.9 })   // limiter at -1 dBFS
    }

    @Test func quietMicrophoneSpeechSurvivesFullChain() throws {
        let speech = try #require(spokenPhrase("Testing, hello, this is my microphone.", rate: 48_000))
        let silence = [Float](repeating: 0, count: 48_000)
        var signal = silence + speech.map { $0 * 0.003 } + silence + silence   // very low gain mic (~ -50 dB)
        var enhancer = MicrophoneEnhancer(sampleRate: 48_000)
        var resampler = StreamingResampler(inputRate: 48_000)
        var c = SileroChunker(model: try SileroVADModel())
        var out: [Utterance] = []
        var i = 0
        while i < signal.count {   // 100 ms ticks, like the capture controller
            let n = min(4_800, signal.count - i)
            var block = Array(signal[i..<(i + n)])
            enhancer.process(&block)
            out += c.append(resampler.process(block), hostTime: Double(i) / 48_000)
            i += n
        }
        if let u = c.flush() { out.append(u) }
        signal.removeAll()
        #expect(out.count >= 1)
    }

    @Test func micArrayDownmixUsesFirstTwoChannels() {
        // Third channel anti-phase (beam-forming aux): averaging all three would nearly cancel the voice.
        let interleaved: [Float] = [0.5, 0.5, -1, 0.2, 0.2, -0.4]
        var out = [Float](repeating: 0, count: 2)
        interleaved.withUnsafeBufferPointer { p in out.withUnsafeMutableBufferPointer { o in Downmix.interleavedToMono(p.baseAddress!, frames: 2, channels: 3, into: o.baseAddress!) } }
        #expect(out == [0.5, 0.2])
    }
}
