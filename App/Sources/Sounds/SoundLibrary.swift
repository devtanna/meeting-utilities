import AppKit
@preconcurrency import AVFoundation
import Foundation
import MeetingCore

/// Original sounds synthesized in code (no third-party audio, no licensing questions), plus the macOS alert sounds.
/// Playback goes through this app's own audio output, which the transcription tap excludes.
struct SoundOption: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var group: String
}

enum SoundLibrary {
    /// One synthesized note: frequency, start offset, duration, timbre.
    struct Note: Sendable {
        var freq: Double
        var start: Double
        var duration: Double
        var gain: Double = 0.6
        var timbre: Timbre = .sine
    }
    enum Timbre: Sendable { case sine, soft, marimba, bell, glass }

    static let synthesized: [(id: String, name: String, notes: [Note])] = [
        ("mu.soft-beep", "Soft Beep", [Note(freq: 880, start: 0, duration: 0.18, timbre: .soft)]),
        ("mu.double-beep", "Double Beep", [Note(freq: 880, start: 0, duration: 0.12, timbre: .soft), Note(freq: 880, start: 0.18, duration: 0.12, timbre: .soft)]),
        ("mu.triple-chirp", "Triple Chirp", [Note(freq: 1318.5, start: 0, duration: 0.08, gain: 0.45), Note(freq: 1568, start: 0.11, duration: 0.08, gain: 0.45),
                                            Note(freq: 1760, start: 0.22, duration: 0.1, gain: 0.45)]),
        ("mu.chime", "Chime", [Note(freq: 1046.5, start: 0, duration: 1.1, timbre: .bell), Note(freq: 1318.5, start: 0.16, duration: 1.2, timbre: .bell)]),
        ("mu.rising", "Rising", [Note(freq: 523.25, start: 0, duration: 0.16, timbre: .soft), Note(freq: 659.25, start: 0.14, duration: 0.16, timbre: .soft),
                                 Note(freq: 783.99, start: 0.28, duration: 0.3, timbre: .soft)]),
        ("mu.marimba", "Marimba", [Note(freq: 587.33, start: 0, duration: 0.5, timbre: .marimba), Note(freq: 880, start: 0.15, duration: 0.6, timbre: .marimba)]),
        ("mu.bell", "Bell", [Note(freq: 659.25, start: 0, duration: 1.8, gain: 0.55, timbre: .bell)]),
        ("mu.glass", "Glass Ping", [Note(freq: 1975.5, start: 0, duration: 0.9, gain: 0.4, timbre: .glass)]),
        ("mu.wood", "Wood Knock", [Note(freq: 392, start: 0, duration: 0.12, gain: 0.7, timbre: .marimba), Note(freq: 392, start: 0.16, duration: 0.12, gain: 0.7, timbre: .marimba)]),
        ("mu.heads-up", "Heads Up", [Note(freq: 783.99, start: 0, duration: 0.14, timbre: .soft), Note(freq: 1046.5, start: 0.16, duration: 0.45, timbre: .bell)]),
    ]

    static let systemNames = ["Glass", "Ping", "Tink", "Purr", "Pop", "Hero", "Submarine", "Blow", "Bottle", "Frog", "Funk", "Morse", "Sosumi", "Basso"]

    static var options: [SoundOption] {
        synthesized.map { SoundOption(id: $0.id, name: $0.name, group: "Meeting Utility") }
            + systemNames.filter { NSSound(named: $0) != nil }.map { SoundOption(id: "sys.\($0)", name: $0, group: "macOS") }
    }

    static func name(_ id: String) -> String { options.first { $0.id == id }?.name ?? "Soft Beep" }

    /// Renders a synthesized sound into an in-memory buffer.
    static func render(_ notes: [Note], sampleRate: Double = 44_100) -> AVAudioPCMBuffer? {
        let total = (notes.map { $0.start + $0.duration }.max() ?? 0) + 0.05
        let frames = AVAudioFrameCount(total * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let out = buf.floatChannelData![0]
        for i in 0..<Int(frames) { out[i] = 0 }
        for n in notes {
            let s0 = Int(n.start * sampleRate), len = Int(n.duration * sampleRate)
            for k in 0..<len where s0 + k < Int(frames) {
                let t = Double(k) / sampleRate
                let w = 2 * Double.pi * n.freq * t
                let attack = min(1, t / 0.006)
                let sample: Double
                switch n.timbre {
                case .sine:
                    sample = sin(w) * attack * max(0, 1 - t / n.duration)
                case .soft:
                    let release = min(1, (n.duration - t) / 0.04)
                    sample = (sin(w) + 0.15 * sin(2 * w)) * attack * max(0, release) * 0.9
                case .marimba:
                    sample = (sin(w) + 0.35 * sin(4 * w) * exp(-t * 30)) * attack * exp(-t * 9)
                case .bell:
                    sample = (sin(w) + 0.5 * sin(2.76 * w) * exp(-t * 3) + 0.25 * sin(5.4 * w) * exp(-t * 6)) * attack * exp(-t * 3.2) * 0.7
                case .glass:
                    sample = (sin(w) + 0.3 * sin(2.01 * w)) * attack * exp(-t * 5)
                }
                out[s0 + k] += Float(sample * n.gain)
            }
        }
        // Normalize to avoid clipping when notes overlap.
        var peak: Float = 0
        for i in 0..<Int(frames) { peak = max(peak, abs(out[i])) }
        if peak > 0.9 { for i in 0..<Int(frames) { out[i] *= 0.9 / peak } }
        return buf
    }
}

/// Plays library sounds at the master volume.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var stopTask: Task<Void, Never>?

    private init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    }

    func play(_ id: String, volume: Double) {
        let v = Float(max(0, min(1, volume)))
        guard v > 0 else { return }
        if id.hasPrefix("sys."), let s = NSSound(named: String(id.dropFirst(4)))?.copy() as? NSSound {
            s.volume = v
            s.play()
            return
        }
        let def = SoundLibrary.synthesized.first { $0.id == id } ?? SoundLibrary.synthesized[0]
        guard let buf = cache[def.id] ?? SoundLibrary.render(def.notes) else { return }
        cache[def.id] = buf
        do {
            if !engine.isRunning { try engine.start() }
            node.volume = v
            node.scheduleBuffer(buf, at: nil, options: .interrupts)
            node.play()
            // Stop the engine shortly after so nothing keeps running while idle (§21.2).
            stopTask?.cancel()
            let seconds = Double(buf.frameLength) / 44_100 + 0.5
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.node.stop(); self?.engine.stop()
            }
        } catch {
            Log.app.error("sound playback failed")
        }
    }
}
