import Foundation

/// Injectable wall clock for planners and tests (§D1, §23.1).
public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}

public final class FixedClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(_ date: Date) { current = date }
    public func now() -> Date { lock.withLock { current } }
    public func set(_ date: Date) { lock.withLock { current = date } }
    public func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Monotonic uptime in seconds, independent of wall-clock changes.
public enum Monotonic {
    public static func seconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}
