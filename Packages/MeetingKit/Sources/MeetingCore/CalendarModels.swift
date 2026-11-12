import Foundation

/// RGBA color stored as plain components so snapshots stay `Sendable` and AppKit-free.
public struct RGBAColor: Sendable, Hashable, Codable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let gray = RGBAColor(red: 0.55, green: 0.55, blue: 0.58)
}

public struct CalendarSnapshot: Sendable, Hashable, Identifiable, Codable {
    public var id: String            // EKCalendar.calendarIdentifier
    public var title: String
    public var sourceID: String
    public var sourceTitle: String
    public var color: RGBAColor
    public init(id: String, title: String, sourceID: String, sourceTitle: String, color: RGBAColor) {
        self.id = id; self.title = title; self.sourceID = sourceID; self.sourceTitle = sourceTitle; self.color = color
    }
}

/// Invitation response for the current user. Never implies attendance (§5.2).
public enum RSVPStatus: String, Sendable, Codable, Hashable {
    case accepted, declined, tentative, pending, organizer, none
}

/// Immutable snapshot of one event occurrence with only the §6.3 fields.
public struct CalendarOccurrenceSnapshot: Sendable, Hashable, Identifiable, Codable {
    /// Stable for one fetch: eventIdentifier + occurrence anchor. Not a storage key (§7.1).
    public var id: String { "\(eventIdentifier)|\(Int((originalOccurrenceDate ?? start).timeIntervalSince1970))" }

    public var sourceID: String
    public var calendarID: String
    public var calendarTitle: String
    public var calendarColor: RGBAColor
    public var calendarItemIdentifier: String
    public var externalIdentifier: String?
    public var eventIdentifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZoneID: String?
    public var originalOccurrenceDate: Date?
    public var isDetached: Bool
    public var isRecurring: Bool
    public var isAllDay: Bool
    public var isCancelled: Bool
    public var rsvp: RSVPStatus
    public var url: String?
    public var location: String?
    public var notes: String?
    public var organizer: String?
    public var lastModified: Date?
    /// Invitees' display names (never emails), the current user excluded; nil when the calendar gave none.
    public var attendees: [String]?
    /// The current user's own name on the invite, when the calendar says which attendee they are.
    public var currentUserName: String?

    public init(
        sourceID: String, calendarID: String, calendarTitle: String = "", calendarColor: RGBAColor = .gray,
        calendarItemIdentifier: String, externalIdentifier: String? = nil, eventIdentifier: String,
        title: String, start: Date, end: Date, timeZoneID: String? = nil, originalOccurrenceDate: Date? = nil,
        isDetached: Bool = false, isRecurring: Bool = false, isAllDay: Bool = false, isCancelled: Bool = false,
        rsvp: RSVPStatus = .accepted, url: String? = nil, location: String? = nil, notes: String? = nil,
        organizer: String? = nil, lastModified: Date? = nil, attendees: [String]? = nil, currentUserName: String? = nil
    ) {
        self.sourceID = sourceID; self.calendarID = calendarID; self.calendarTitle = calendarTitle
        self.calendarColor = calendarColor; self.calendarItemIdentifier = calendarItemIdentifier
        self.externalIdentifier = externalIdentifier; self.eventIdentifier = eventIdentifier
        self.title = title; self.start = start; self.end = end; self.timeZoneID = timeZoneID
        self.originalOccurrenceDate = originalOccurrenceDate; self.isDetached = isDetached
        self.isRecurring = isRecurring; self.isAllDay = isAllDay; self.isCancelled = isCancelled
        self.rsvp = rsvp; self.url = url; self.location = location; self.notes = notes
        self.organizer = organizer; self.lastModified = lastModified
        self.attendees = attendees; self.currentUserName = currentUserName
    }

    /// Anchor that stays stable when a detached recurrence instance moves (§7.2).
    public var recurrenceAnchor: Date { originalOccurrenceDate ?? start }

    public func overlaps(_ other: CalendarOccurrenceSnapshot) -> Bool {
        start < other.end && other.start < end
    }

    public func isActive(at date: Date) -> Bool { start <= date && date < end }
}

public enum CalendarAuthorization: String, Sendable, Codable {
    case notDetermined, denied, restricted, writeOnly, fullAccess

    public var canRead: Bool { self == .fullAccess }
}

public enum CalendarChange: Sendable {
    case storeChanged
    case authorizationChanged(CalendarAuthorization)
}

public enum CalendarRepositoryError: Error, Sendable, Equatable {
    case notAuthorized(CalendarAuthorization)
    case calendarUnavailable(String)
    case fetchFailed(String)
}

/// Reads only. The app never saves, deletes, or modifies calendar events (§6.1).
public protocol CalendarRepository: Sendable {
    func authorization() async -> CalendarAuthorization
    func requestAccess() async -> CalendarAuthorization
    func calendars() async throws -> [CalendarSnapshot]
    func occurrences(in range: DateInterval, calendarIDs: Set<String>) async throws -> [CalendarOccurrenceSnapshot]
    func changes() -> AsyncStream<CalendarChange>
}

/// Freshness of a calendar working set. A failed refresh never becomes an authoritative empty result (§6.2).
public struct CalendarFreshness: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case neverLoaded
        case fresh
        case stale(reason: String)
    }
    public var generation: Int
    public var lastSuccess: Date?
    public var state: State
    public var missingCalendarIDs: Set<String>

    public init(generation: Int = 0, lastSuccess: Date? = nil, state: State = .neverLoaded, missingCalendarIDs: Set<String> = []) {
        self.generation = generation; self.lastSuccess = lastSuccess; self.state = state; self.missingCalendarIDs = missingCalendarIDs
    }

    /// Automatic actions (auto join, auto capture) require fresh data for the active generation (§11.1).
    public var permitsAutomation: Bool { state == .fresh }
}

/// Bounded fetch ranges (§6.2).
public enum FetchRanges {
    public static func agenda(now: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: start)!
        return DateInterval(start: start, end: end)
    }

    public static func day(_ date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    public static func planner(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-15 * 60), duration: 48 * 3600 + 15 * 60)
    }

    /// Visible month grid including adjacent days (6 rows x 7 days).
    public static func monthGrid(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let firstOfMonth = calendar.date(from: comps)!
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: firstOfMonth)!
        let gridEnd = calendar.date(byAdding: .day, value: 42, to: gridStart)!
        return DateInterval(start: gridStart, end: gridEnd)
    }
}
