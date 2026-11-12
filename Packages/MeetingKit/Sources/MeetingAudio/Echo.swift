import Foundation
import MeetingCore

// Without headphones the microphone hears the other side's voice from the speakers, so their words come back as
// "You". Whether that is happening is decided from the audio, not the words: the mic's loudness envelope is compared
// with the system track's over 2 s windows while both carry sound; their voice from the speakers makes the two move
// together, a little late, at the same lag every time. Two people talking over each other correlate now and then at
// random lags, so echo is a rate at a steady lag, never a count. Only with that evidence is a mic line that repeats
// their words dropped; with headphones a short reply that echoes their words is the person's own.
// Adapted from Yogurt (FrigadeHQ/yogurt, MIT, app/src/main/asr/echoDetect.ts and echo.ts); see THIRD_PARTY_NOTICES.md.

/// What a mic line's own audio says about echo.
public struct EchoMoment: Sendable, Equatable {
    /// The mic followed their track over the line, at the room's lag.
    public var correlated: Bool
    /// The mic was no louder than their leaked voice usually is (little on it beyond their voice).
    public var atLeakLevel: Bool
    /// Nothing on the mic but their voice from the speakers.
    public var pure: Bool
}

public final class EchoMonitor: @unchecked Sendable {
    static let blocksPerSecond = 100
    static let samplesPerBlock = 160               // 10 ms at 16 kHz
    static let windowBlocks = 200                  // 2 s
    static let maxLagBlocks = 30                   // the speakers-to-mic path is well under 300 ms
    static let ringBlocks = 2 * 3600 * 100         // two hours of envelope per track
    /// Their track is talking in a window from this mean level up; the mic shows something from this up.
    static let themLoud: Float = 0.004
    static let meSome: Float = 0.0006
    static let correlated: Float = 0.6
    static let minActive = 10
    static let minRate = 0.4
    static let minSteady = 0.7
    static let strongRate = 0.55
    static let lineMinSpeaking = 20
    static let lagSlack = 2
    static let loudRatio: Float = 2
    static let pureCorrelation: Float = 0.8
    static let pureRatio: Float = 1.5
    static let pureCover = 0.4

    private let lock = NSLock()
    private var origin: Double = 0
    private var sumSq: [CaptureSource: [Float]] = [:]
    private var count: [CaptureSource: [UInt16]] = [:]
    private var latest: [CaptureSource: Int] = [:]
    /// End (exclusive) of the next 2 s window to judge; windows are aligned to multiples of `windowBlocks`.
    private var nextCheck = 2 * windowBlocks
    private var active = 0
    private var lags: [Int] = []
    private var ratios: [Float] = []
    private var correlatedWindows = Set<Int>()

    public init() {}

    public func reset(origin: Double) {
        lock.withLock {
            self.origin = origin
            sumSq = [:]; count = [:]; latest = [:]
            nextCheck = 2 * Self.windowBlocks
            active = 0; lags = []; ratios = []; correlatedWindows = []
        }
    }

    /// Feeds 16 kHz mono audio of one source; `hostTime` is when its first sample was heard.
    public func append(_ source: CaptureSource, samples: [Float], hostTime: Double) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            if sumSq[source] == nil {
                sumSq[source] = [Float](repeating: 0, count: Self.ringBlocks)
                count[source] = [UInt16](repeating: 0, count: Self.ringBlocks)
                latest[source] = -1
            }
            let startBlock = (hostTime - origin) * Double(Self.blocksPerSecond)
            guard startBlock >= 0 else { return }
            var last = latest[source] ?? -1
            let perBlock = Double(Self.samplesPerBlock)
            samples.withUnsafeBufferPointer { p in
                var i = 0
                while i < p.count {
                    // The 10 ms block this sample falls in, and the first sample of the next block.
                    let block = Int((startBlock + Double(i) / perBlock).rounded(.down))
                    let end = min(max(Int(((Double(block + 1) - startBlock) * perBlock).rounded(.up)), i + 1), p.count)
                    let slot = block % Self.ringBlocks
                    if block > last {
                        // Clear the slots this track moves into (a ring: they still hold audio from two hours ago).
                        for b in max(last + 1, block - Self.ringBlocks + 1)...block { sumSq[source]![b % Self.ringBlocks] = 0; count[source]![b % Self.ringBlocks] = 0 }
                        last = block
                    }
                    var acc: Float = 0
                    for j in i..<end { acc += p[j] * p[j] }
                    sumSq[source]![slot] += acc
                    count[source]![slot] = count[source]![slot] &+ UInt16(clamping: end - i)
                    i = end
                }
            }
            latest[source] = last
            evaluateWindows()
        }
    }

    /// Whether their voice is reaching the mic in this meeting.
    public var echoPresent: Bool { lock.withLock { present() } }

    /// Did the mic follow their track in the 2 s window holding this moment?
    public func correlatedAt(_ hostTime: Double) -> Bool {
        lock.withLock { correlatedWindows.contains(Int((hostTime - origin) * Double(Self.blocksPerSecond)) / Self.windowBlocks) }
    }

    /// What one mic line's span says (nil until the room's lag is known, or when their side barely spoke over it).
    public func moment(start: Double, end: Double) -> EchoMoment? {
        lock.withLock {
            guard let lag = roomLag(), let leak = median(ratios) else { return nil }
            let a = Int((start - origin) * Double(Self.blocksPerSecond)), b = Int((end - origin) * Double(Self.blocksPerSecond))
            guard b > a, a - lag - Self.lagSlack >= 0 else { return nil }
            let me = levels(.microphone, a, b)
            var bestCorr: Float = -1, bestThem: [Float] = []
            for l in max(0, lag - Self.lagSlack)...(lag + Self.lagSlack) {
                let them = levels(.system, a - l, b - l)
                let c = Self.correlation(me, them)
                if c > bestCorr { bestCorr = c; bestThem = them }
            }
            let speaking = bestThem.filter { $0 >= Self.themLoud }.count
            guard speaking >= Self.lineMinSpeaking else { return nil }
            let meanMe = me.reduce(0, +) / Float(max(me.count, 1)), meanThem = bestThem.reduce(0, +) / Float(max(bestThem.count, 1))
            let ratio = meanThem > 0 ? meanMe / meanThem : .infinity
            let cover = Double(speaking) / Double(max(me.count, 1))
            return EchoMoment(correlated: bestCorr >= Self.correlated, atLeakLevel: ratio <= leak * Self.loudRatio,
                              pure: bestCorr >= Self.pureCorrelation && ratio <= leak * Self.pureRatio && cover >= Self.pureCover)
        }
    }

    // MARK: - Private (lock held)

    private func levels(_ s: CaptureSource, _ a: Int, _ b: Int) -> [Float] {
        guard let sq = sumSq[s], let n = count[s], let last = latest[s] else { return [] }
        return (a..<b).map { blk in
            guard blk >= 0, blk <= last, last - blk < Self.ringBlocks else { return 0 }
            let c = n[blk % Self.ringBlocks]
            return c > 0 ? (sq[blk % Self.ringBlocks] / Float(c)).squareRoot() : 0
        }
    }

    private func evaluateWindows() {
        guard let me = latest[.microphone], let them = latest[.system] else { return }
        while min(me, them) >= nextCheck {
            let w0 = nextCheck, start = w0 - Self.windowBlocks
            defer { nextCheck += Self.windowBlocks }
            let mic = levels(.microphone, start, w0)
            let meanMe = mic.reduce(0, +) / Float(mic.count)
            let theirsNow = levels(.system, start, w0)
            let meanThem = theirsNow.reduce(0, +) / Float(theirsNow.count)
            guard meanThem >= Self.themLoud, meanMe >= Self.meSome else { continue }
            active += 1
            var best: Float = -1, bestLag = 0, bestThemMean: Float = 0
            for lag in 0...Self.maxLagBlocks {
                let t = levels(.system, start - lag, w0 - lag)
                let c = Self.correlation(mic, t)
                if c > best { best = c; bestLag = lag; bestThemMean = t.reduce(0, +) / Float(t.count) }
            }
            if best >= Self.correlated, bestThemMean > 0 {
                lags.append(bestLag)
                ratios.append(meanMe / bestThemMean)
                correlatedWindows.insert(start / Self.windowBlocks)
            }
        }
    }

    private func present() -> Bool {
        guard active >= Self.minActive else { return false }
        let rate = Double(lags.count) / Double(active)
        if rate >= Self.strongRate { return true }
        guard rate >= Self.minRate, let lag = roomLag() else { return false }
        let steady = Double(lags.filter { abs($0 - lag) <= Self.lagSlack }.count) / Double(lags.count)
        return steady >= Self.minSteady
    }

    private func roomLag() -> Int? {
        guard !lags.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for l in lags { counts[l, default: 0] += 1 }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    private func median(_ xs: [Float]) -> Float? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 2 else { return 0 }
        var ma: Float = 0, mb: Float = 0
        for i in 0..<n { ma += a[i]; mb += b[i] }
        ma /= Float(n); mb /= Float(n)
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<n { let x = a[i] - ma, y = b[i] - mb; num += x * y; da += x * x; db += y * y }
        let den = (da * db).squareRoot()
        return den > 0 ? num / den : 0
    }
}

/// Word-level check of a mic line against what the other side said at that moment.
public enum EchoText {
    /// A line from the other side, on the capture clock.
    public struct Line: Sendable { public var start: Double; public var end: Double; public var text: String
        public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text } }

    static let window = 1.5
    static let tail = 0.5
    static let longTokens = 8, midTokens = 6, minTokens = 3
    static let threshold = 0.6, midThreshold = 0.8, shortThreshold = 0.95, joinedThreshold = 0.75

    /// Words, lowercased and without punctuation.
    public static func tokens(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// How many of `a`'s words `b` has too (each counted as often as it appears in both).
    static func shared(_ a: [String], _ b: [String]) -> Int {
        var left: [String: Int] = [:]
        for w in b { left[w, default: 0] += 1 }
        var n = 0
        for w in a where (left[w] ?? 0) > 0 { n += 1; left[w]! -= 1 }
        return n
    }

    /// Is this mic line a copy of their voice? Only asked once the audio showed echo in this meeting.
    public static func isEcho(mic: Line, theirs: [Line], moment: EchoMoment?, correlatedAt: Bool) -> Bool {
        // The mic was clearly louder than their leak: the person talking (over them), whatever the words.
        if let m = moment, !m.atLeakLevel { return false }
        let near = theirs.filter { $0.start <= mic.end + window && $0.end + tail >= mic.start - window && mic.start <= $0.end + tail + window }
        guard !near.isEmpty else { return false }
        let t = tokens(mic.text)
        let them = near.flatMap { tokens($0.text) }
        guard !t.isEmpty, !them.isEmpty else { return false }
        let share = Double(shared(t, them)) / Double(t.count)
        let echoedNow = moment?.correlated ?? correlatedAt
        if t.count < minTokens { return (moment?.pure ?? false) && share >= 1 }
        if t.count < midTokens { return echoedNow && share >= shortThreshold }
        if t.count < longTokens { return share >= midThreshold }
        return share >= (near.count > 1 ? joinedThreshold : threshold)
    }
}
