import Foundation

/// Gregorian calendar-quarter arithmetic (§17). Never divides seconds by 86,400.
public struct QuarterInfo: Sendable, Equatable {
    public var year: Int
    public var quarter: Int
    public var quarterStart: Date
    public var nextQuarterStart: Date
    public var nextQuarter: Int
    public var nextQuarterYear: Int
    public var elapsedCompleteDays: Int
    public var dayOfQuarter: Int
    public var quarterLength: Int
    public var daysToNextQuarter: Int

    public var shortLabel: String { "Q\(quarter) \(dayOfQuarter)/\(quarterLength) \(daysToNextQuarter)D Q\(nextQuarter)" }
    public var chipLabel: String { "Q\(quarter) \(year) · Day \(dayOfQuarter) of \(quarterLength)" }
}

public enum QuarterCore {
    /// - Parameters:
    ///   - date: the instant whose local civil date is used
    ///   - timeZone: user's current local time zone
    public static func info(for date: Date, timeZone: TimeZone = .current) -> QuarterInfo {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let year = comps.year!, month = comps.month!
        let quarter = ((month - 1) / 3) + 1
        let startMonth = (quarter - 1) * 3 + 1
        let quarterStart = cal.date(from: DateComponents(year: year, month: startMonth, day: 1))!
        let nextStart = cal.date(byAdding: .month, value: 3, to: quarterStart)!
        let today = cal.date(from: DateComponents(year: year, month: month, day: comps.day!))!
        let elapsed = cal.dateComponents([.day], from: quarterStart, to: today).day!
        let length = cal.dateComponents([.day], from: quarterStart, to: nextStart).day!
        let toNext = cal.dateComponents([.day], from: today, to: nextStart).day!
        let nextComps = cal.dateComponents([.year, .month], from: nextStart)
        return QuarterInfo(
            year: year, quarter: quarter, quarterStart: quarterStart, nextQuarterStart: nextStart,
            nextQuarter: ((nextComps.month! - 1) / 3) + 1, nextQuarterYear: nextComps.year!,
            elapsedCompleteDays: elapsed, dayOfQuarter: elapsed + 1, quarterLength: length, daysToNextQuarter: toNext)
    }

    /// Next local midnight, used to schedule exactly one update timer (§17.2).
    public static func nextMidnight(after date: Date, timeZone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: 1, to: start)!
    }
}
