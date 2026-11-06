import Foundation

public enum AutomaticActionKind: String, Sendable, Codable { case autoJoin }

public enum AutomaticActionState: String, Sendable, Codable {
    case requested, succeeded, failed, ambiguous
}

/// Facts needed to decide auto-join eligibility for one occurrence (§11.1).
public struct AutoJoinCandidate: Sendable, Equatable {
    public var occurrenceID: UUID
    public var start: Date
    public var end: Date
    public var autoJoinEnabled: Bool          // resolved occurrence → series → global
    public var explicitlyIncluded: Bool       // explicit override for non-accepted invites
    public var linkCount: Int
    public var isCancelled: Bool
    public var rsvp: RSVPStatus
    public var isDismissed: Bool
    public var isAllDay: Bool
    public var ledgerState: AutomaticActionState?

    public init(occurrenceID: UUID, start: Date, end: Date, autoJoinEnabled: Bool, explicitlyIncluded: Bool = false,
                linkCount: Int = 1, isCancelled: Bool = false, rsvp: RSVPStatus = .accepted, isDismissed: Bool = false,
                isAllDay: Bool = false, ledgerState: AutomaticActionState? = nil) {
        self.occurrenceID = occurrenceID; self.start = start; self.end = end; self.autoJoinEnabled = autoJoinEnabled
        self.explicitlyIncluded = explicitlyIncluded; self.linkCount = linkCount; self.isCancelled = isCancelled
        self.rsvp = rsvp; self.isDismissed = isDismissed; self.isAllDay = isAllDay; self.ledgerState = ledgerState
    }
}

public enum AutoJoinIneligibility: String, Sendable, Equatable {
    case disabled, noLink, multipleLinks, cancelled, declined, dismissed, allDay, notAccepted, alreadyAttempted
}

public enum AutoJoinDecision: Sendable, Equatable {
    case join(UUID)
    case askUser([UUID])
    case suppressedByActiveCapture(UUID)
    case suppressedStaleCalendar
    case nothing
}

public enum AutoJoinPlanner {
    public static let dispatchTolerance: TimeInterval = 10

    public static func ineligibility(_ c: AutoJoinCandidate) -> AutoJoinIneligibility? {
        if !c.autoJoinEnabled { return .disabled }
        if c.isCancelled { return .cancelled }
        if c.isAllDay { return .allDay }
        if c.isDismissed { return .dismissed }
        if c.rsvp == .declined { return .declined }
        if ![.accepted, .organizer, .none].contains(c.rsvp) && !c.explicitlyIncluded { return .notAccepted }
        if c.linkCount == 0 { return .noLink }
        if c.linkCount > 1 { return .multipleLinks }
        if c.ledgerState != nil { return .alreadyAttempted }
        return nil
    }

    /// The next instant the scheduler must wake: the earliest eligible start strictly after `now`.
    public static func nextBoundary(candidates: [AutoJoinCandidate], now: Date) -> Date? {
        candidates.filter { ineligibility($0) == nil && $0.start > now }.map(\.start).min()
    }

    /// Decide what to do when the timer fires at `now`.
    /// - Parameter armedAt: wall time when the current plan was armed while the app was continuously running.
    ///   Starts before `armedAt` were missed (sleep, launch) and never trigger catch-up (§11.1).
    public static func decide(
        candidates: [AutoJoinCandidate], now: Date, armedAt: Date,
        calendarFresh: Bool, activeCaptureOccurrence: UUID?
    ) -> AutoJoinDecision {
        let due = candidates.filter {
            ineligibility($0) == nil && $0.start <= now && now.timeIntervalSince($0.start) <= dispatchTolerance && $0.start >= armedAt
        }
        guard !due.isEmpty else { return .nothing }
        guard calendarFresh else { return .suppressedStaleCalendar }
        if let active = activeCaptureOccurrence, !due.contains(where: { $0.occurrenceID == active }) {
            return .suppressedByActiveCapture(due[0].occurrenceID)
        }
        if due.count > 1 {
            return .askUser(due.sorted { $0.occurrenceID.uuidString < $1.occurrenceID.uuidString }.map(\.occurrenceID))
        }
        // An overlapping eligible meeting starting at a different time is not ambiguous; a simultaneous one is.
        return .join(due[0].occurrenceID)
    }
}

/// Scoped settings resolution: occurrence → series → global (§19.1).
public enum ScopedValue {
    public static func resolve<T>(occurrence: T?, series: T?, global: T) -> (value: T, inheritedFrom: Scope) {
        if let occurrence { return (occurrence, .occurrence) }
        if let series { return (series, .series) }
        return (global, .global)
    }

    public enum Scope: String, Sendable { case occurrence, series, global }
}
