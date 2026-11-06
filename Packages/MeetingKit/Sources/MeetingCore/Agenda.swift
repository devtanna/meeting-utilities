import Foundation

public struct AgendaFilters: Sendable, Equatable, Codable {
    public var hideAllDay = false
    public var hideDeclined = false
    public var hideTentative = false
    public var hideLinkless = false
    /// No longer used: dismissed occurrences always stay in the agenda (dimmed). Kept so saved settings decode.
    public var showDismissed = false
    public init(hideAllDay: Bool = false, hideDeclined: Bool = false, hideTentative: Bool = false,
                hideLinkless: Bool = false, showDismissed: Bool = false) {
        self.hideAllDay = hideAllDay; self.hideDeclined = hideDeclined; self.hideTentative = hideTentative
        self.hideLinkless = hideLinkless; self.showDismissed = showDismissed
    }
}

/// A row ready for presentation: the snapshot plus app-derived facts.
public struct AgendaItem: Sendable, Hashable, Identifiable {
    public var id: String { event.id }
    public var event: CalendarOccurrenceSnapshot
    public var primaryLink: MeetingLinkCandidate?
    public var alternativeLinks: [MeetingLinkCandidate]
    public var isDismissed: Bool

    public init(event: CalendarOccurrenceSnapshot, primaryLink: MeetingLinkCandidate?,
                alternativeLinks: [MeetingLinkCandidate] = [], isDismissed: Bool = false) {
        self.event = event; self.primaryLink = primaryLink; self.alternativeLinks = alternativeLinks; self.isDismissed = isDismissed
    }
}

public struct AgendaSection: Sendable, Hashable, Identifiable {
    public var id: Date { day }
    public var day: Date
    public var items: [AgendaItem]
}

public enum AgendaBuilder {
    /// Deterministic order: start, then end, then title, then identifier (§23.1 stable sorting).
    public static func sort(_ items: [AgendaItem]) -> [AgendaItem] {
        items.sorted { a, b in
            if a.event.isAllDay != b.event.isAllDay { return a.event.isAllDay }
            if a.event.start != b.event.start { return a.event.start < b.event.start }
            if a.event.end != b.event.end { return a.event.end < b.event.end }
            if a.event.title != b.event.title { return a.event.title.localizedStandardCompare(b.event.title) == .orderedAscending }
            return a.event.id < b.event.id
        }
    }

    public static func applyFilters(_ items: [AgendaItem], filters: AgendaFilters) -> [AgendaItem] {
        items.filter { item in
            let e = item.event
            if e.isCancelled { return false }
            // Dismissed occurrences stay listed (dimmed); dismissing only affects the menu bar, reminders and sounds.
            if filters.hideAllDay && e.isAllDay { return false }
            if filters.hideDeclined && e.rsvp == .declined { return false }
            if filters.hideTentative && e.rsvp == .tentative { return false }
            if filters.hideLinkless && item.primaryLink == nil { return false }
            return true
        }
    }

    /// Groups into local days. Multi-day events appear on every day they cover within `days`.
    public static func sections(_ items: [AgendaItem], days: [Date], calendar: Calendar = .current) -> [AgendaSection] {
        days.map { dayStart in
            let day = calendar.startOfDay(for: dayStart)
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let dayItems = items.filter { $0.event.start < next && $0.event.end > day || ($0.event.start == $0.event.end && $0.event.start >= day && $0.event.start < next) }
            return AgendaSection(day: day, items: sort(dayItems))
        }
    }

    /// Current meeting, otherwise next eligible upcoming meeting (§5.2). All-day, declined, dismissed are skipped.
    public static func focusItem(_ items: [AgendaItem], now: Date) -> AgendaItem? {
        let candidates = sort(items.filter {
            !$0.event.isAllDay && !$0.event.isCancelled && $0.event.rsvp != .declined && !$0.isDismissed && $0.event.end > now
        })
        if let current = candidates.first(where: { $0.event.isActive(at: now) }) { return current }
        return candidates.first { $0.event.start >= now }
    }

    /// What the compact menu-bar status shows, honouring the display options:
    /// - `lookaheadMinutes`: an upcoming meeting appears only when it starts within this many minutes (nil = any time
    ///   today). Upcoming meetings are always limited to today; tomorrow's first meeting never shows tonight.
    /// - `hideCurrentAfterMinutes`: a running meeting is hidden once it has run this long (nil = keep until it ends,
    ///   0 = hide as soon as it starts); the next meeting can then take its place.
    public static func menuBarItem(_ items: [AgendaItem], now: Date, lookaheadMinutes: Int?, hideCurrentAfterMinutes: Int?,
                                   calendar: Calendar = .current) -> AgendaItem? {
        let candidates = sort(items.filter {
            !$0.event.isAllDay && !$0.event.isCancelled && $0.event.rsvp != .declined && !$0.isDismissed && $0.event.end > now
        })
        let current = candidates.first { e in
            guard e.event.isActive(at: now) else { return false }
            guard let after = hideCurrentAfterMinutes else { return true }
            return now.timeIntervalSince(e.event.start) < Double(after) * 60
        }
        if let current { return current }
        guard let next = candidates.first(where: { $0.event.start > now }),
              calendar.isDate(next.event.start, inSameDayAs: now) else { return nil }
        if let look = lookaheadMinutes, next.event.start.timeIntervalSince(now) > Double(look) * 60 { return nil }
        return next
    }

    /// All overlapping meetings that are current at `now` — a join shortcut must ask when more than one (§5.2).
    public static func ambiguousJoinTargets(_ items: [AgendaItem], now: Date) -> [AgendaItem] {
        sort(items.filter { !$0.event.isAllDay && $0.event.isActive(at: now) && $0.primaryLink != nil && !$0.isDismissed && $0.event.rsvp != .declined })
    }
}

public enum StatusTitleLength: String, Sendable, Codable, CaseIterable {
    case iconOnly, short, medium, long
    public var maxTitleCharacters: Int? {
        switch self {
        case .iconOnly: 0
        case .short: 12
        case .medium: 24
        case .long: 40
        }
    }
}

public enum CompactStatusContent: String, Sendable, Codable, CaseIterable {
    case meeting, quarter, meetingAndQuarter
}

public enum CountdownFormatter {
    /// Countdown: minutes up to an hour away, whole hours beyond, e.g. "in 54m", "in 60m", "in 2h", "now", "12m left".
    public static func phrase(for item: AgendaItem, now: Date) -> String {
        let e = item.event
        if e.isActive(at: now) {
            let left = Int(ceil(e.end.timeIntervalSince(now) / 60))
            return left <= 0 ? "ending" : "\(format(minutes: left)) left"
        }
        let mins = Int(ceil(e.start.timeIntervalSince(now) / 60))
        if mins <= 0 { return "now" }
        return "in \(format(minutes: mins))"
    }

    /// Minutes only within the last hour ("45m", "60m"); beyond that whole hours, rounded down ("2h" for 2h 37m).
    public static func format(minutes: Int) -> String {
        minutes <= 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }

    public static func truncate(_ s: String, to max: Int?) -> String {
        guard let max else { return s }
        if max <= 0 { return "" }
        if s.count <= max { return s }
        return String(s.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "Title • in 54m" (§5.1 reference).
    public static func statusTitle(item: AgendaItem?, now: Date, length: StatusTitleLength) -> String {
        guard let item else { return "" }
        if length == .iconOnly { return "" }
        let title = truncate(item.event.title, to: length.maxTitleCharacters)
        // For the first minute after the start time the meeting reads "now" (then "29m left").
        let sinceStart = now.timeIntervalSince(item.event.start)
        return "\(title) • \(sinceStart >= 0 && sinceStart < 60 ? "now" : phrase(for: item, now: now))"
    }

    /// Next instant at which the minute-level status string may change. Used to schedule a single timer
    /// instead of polling every second (§11.1, §21.2 wakeups).
    public static func nextRefresh(after now: Date, items: [AgendaItem]) -> Date {
        let nextMinute = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 60) + 1) * 60)
        var candidate = nextMinute
        for i in items {
            for t in [i.event.start, i.event.start.addingTimeInterval(60), i.event.end] where t > now && t < candidate { candidate = t }
        }
        return candidate
    }
}
