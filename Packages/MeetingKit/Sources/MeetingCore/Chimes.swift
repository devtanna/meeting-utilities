import Foundation

/// Timing for meeting sounds and interval chimes. One next-fire instant at a time; no polling.
public enum ChimePlanner {
    public static let intervalOptions = [15, 30, 45, 60]
    public static let leadOptions = [0, 1, 2, 3, 5, 10, 15]
    /// A sound whose time passed more than this long ago (sleep, launch) is skipped, never replayed late.
    public static let lateTolerance: TimeInterval = 20

    /// Next clock-aligned interval boundary strictly after `now` (e.g. every 30 min → :00 and :30 local time).
    public static func nextInterval(after now: Date, everyMinutes: Int, calendar: Calendar = .current) -> Date {
        let minutes = max(1, everyMinutes)
        let dayStart = calendar.startOfDay(for: now)
        let elapsed = now.timeIntervalSince(dayStart)
        let step = Double(minutes) * 60
        var next = dayStart.addingTimeInterval((floor(elapsed / step) + 1) * step)
        // Intervals that do not divide a day (45 min) restart at midnight.
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        if next > nextDay { next = nextDay }
        return next
    }

    /// When the interval chime may play: selected weekdays (Calendar weekday, 1 = Sunday … 7 = Saturday) and an hour
    /// range. `endHour` is inclusive of its exact boundary (9–18 chimes at 18:00 but not 18:30). If `startHour` is
    /// after `endHour` the range runs overnight (22–6). Equal hours mean all day.
    public struct ChimeWindow: Equatable, Sendable, Codable {
        public var weekdays: Set<Int>
        public var startHour: Int
        public var endHour: Int

        public init(weekdays: Set<Int>, startHour: Int, endHour: Int) {
            self.weekdays = weekdays
            self.startHour = min(max(startHour, 0), 24)
            self.endHour = min(max(endHour, 0), 24)
        }

        public static let always = ChimeWindow(weekdays: Set(1...7), startHour: 0, endHour: 24)
        public static let workdays = ChimeWindow(weekdays: Set(2...6), startHour: 9, endHour: 18)

        public var isAllDay: Bool { startHour == endHour || (startHour == 0 && endHour == 24) }

        /// True if a chime at `date` falls inside the window. For overnight ranges the weekday is that of the evening
        /// the range started (Fri 22–6 covers Saturday 02:00).
        public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
            let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
            guard let weekday = c.weekday, let hour = c.hour, let minute = c.minute else { return false }
            let m = hour * 60 + minute
            let start = startHour * 60, end = endHour * 60
            if isAllDay { return weekdays.contains(weekday) }
            if start < end { return weekdays.contains(weekday) && m >= start && m <= end }
            if m >= start { return weekdays.contains(weekday) }           // evening part
            let previous = weekday == 1 ? 7 : weekday - 1                  // early-morning part belongs to the day before
            return m <= end && weekdays.contains(previous)
        }
    }

    /// Next clock-aligned boundary strictly after `now` that falls inside `window`, or nil if none within 8 days
    /// (no weekdays selected).
    public static func nextInterval(after now: Date, everyMinutes: Int, window: ChimeWindow, calendar: Calendar = .current) -> Date? {
        let limit = now.addingTimeInterval(8 * 86_400)
        var t = nextInterval(after: now, everyMinutes: everyMinutes, calendar: calendar)
        while t < limit {
            if window.contains(t, calendar: calendar) { return t }
            t = nextInterval(after: t, everyMinutes: everyMinutes, calendar: calendar)
        }
        return nil
    }

    public struct MeetingCue: Equatable, Sendable {
        public var key: String       // stable per occurrence + start, so a cue fires once
        public var fireAt: Date
    }

    /// Cues for upcoming meetings: start − lead. Only future cues (or ones within the late tolerance) are returned.
    public static func meetingCues(_ items: [AgendaItem], leadMinutes: Int, now: Date, alreadyPlayed: Set<String>) -> [MeetingCue] {
        items.compactMap { i in
            let e = i.event
            guard !e.isAllDay, !e.isCancelled, e.rsvp != .declined, !i.isDismissed else { return nil }
            let fire = e.start.addingTimeInterval(-Double(leadMinutes) * 60)
            let key = "\(e.id)|\(Int(e.start.timeIntervalSince1970))|\(leadMinutes)"
            guard !alreadyPlayed.contains(key), fire > now.addingTimeInterval(-lateTolerance) else { return nil }
            return MeetingCue(key: key, fireAt: fire)
        }
        .sorted { $0.fireAt < $1.fireAt }
    }
}
