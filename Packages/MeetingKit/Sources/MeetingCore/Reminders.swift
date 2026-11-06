import Foundation

public enum ReminderOffset: Int, Sendable, Codable, CaseIterable, Comparable {
    case five = 5, ten = 10, fifteen = 15
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum ReminderPreview: String, Sendable, Codable, CaseIterable {
    case meetingTitle, generic
}

/// Input for the planner: one occurrence with its stable app UUID and current state.
public struct PlannableOccurrence: Sendable, Equatable {
    public var occurrenceID: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isCancelled: Bool
    public var rsvp: RSVPStatus
    public var isDismissed: Bool
    public var hasLink: Bool
    public var linkCount: Int

    public init(occurrenceID: UUID, title: String, start: Date, end: Date, isAllDay: Bool = false, isCancelled: Bool = false,
                rsvp: RSVPStatus = .accepted, isDismissed: Bool = false, hasLink: Bool = true, linkCount: Int = 1) {
        self.occurrenceID = occurrenceID; self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.isCancelled = isCancelled; self.rsvp = rsvp; self.isDismissed = isDismissed; self.hasLink = hasLink; self.linkCount = linkCount
    }
}

public struct ReminderRequest: Sendable, Equatable, Hashable {
    public var identifier: String
    public var occurrenceID: UUID
    public var offset: ReminderOffset
    public var fireDate: Date
    public var title: String
    public var body: String
}

/// Deterministic, bounded reminder plan (§11.3–11.4).
public enum ReminderPlanner {
    public static let horizon: TimeInterval = 48 * 3600
    public static let softCap = 48

    /// Stable ID derived from occurrence UUID + offset, never title or URL.
    public static func identifier(occurrenceID: UUID, offset: ReminderOffset) -> String {
        "reminder.\(occurrenceID.uuidString.lowercased()).\(offset.rawValue)"
    }

    public static func parse(identifier: String) -> (UUID, ReminderOffset)? {
        let parts = identifier.split(separator: ".")
        guard parts.count == 3, parts[0] == "reminder", let id = UUID(uuidString: String(parts[1])),
              let mins = Int(parts[2]), let off = ReminderOffset(rawValue: mins) else { return nil }
        return (id, off)
    }

    public static func plan(
        occurrences: [PlannableOccurrence], offsets: Set<ReminderOffset>, now: Date,
        preview: ReminderPreview, timeFormatter: (Date) -> String
    ) -> [ReminderRequest] {
        guard !offsets.isEmpty else { return [] }
        var out: [ReminderRequest] = []
        for occ in occurrences {
            guard !occ.isCancelled, !occ.isDismissed, !occ.isAllDay, occ.rsvp != .declined else { continue }
            for off in offsets.sorted() {
                let fire = occ.start.addingTimeInterval(-Double(off.rawValue) * 60)
                // Never replay missed reminders (§11.3).
                guard fire > now, fire <= now.addingTimeInterval(horizon) else { continue }
                let title = preview == .meetingTitle ? occ.title : "Upcoming meeting"
                let body = "Starts at \(timeFormatter(occ.start)) · in \(off.rawValue) min"
                out.append(ReminderRequest(identifier: identifier(occurrenceID: occ.occurrenceID, offset: off),
                                           occurrenceID: occ.occurrenceID, offset: off, fireDate: fire, title: title, body: body))
            }
        }
        out.sort { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }
        return Array(out.prefix(softCap))
    }

    /// Diff against currently pending identifiers: what to add and what to remove.
    public static func reconcile(desired: [ReminderRequest], pending: Set<String>) -> (add: [ReminderRequest], remove: Set<String>) {
        let desiredIDs = Set(desired.map(\.identifier))
        let ours = pending.filter { $0.hasPrefix("reminder.") }
        return (desired.filter { !pending.contains($0.identifier) }, ours.subtracting(desiredIDs))
    }
}

/// Notification action identifiers. Payload carries only an opaque occurrence ID (§11.3).
public enum NotificationActionID {
    public static let category = "MEETING_REMINDER"
    public static let join = "JOIN"
    public static let openNotes = "OPEN_NOTES"
    public static let dismiss = "DISMISS"
    public static let occurrenceKey = "occurrence"
}
