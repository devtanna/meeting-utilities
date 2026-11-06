import AppKit
@preconcurrency import EventKit
import Foundation
import MeetingCore

/// One actor owns EKEventStore and every EKEvent/EKCalendar; only immutable snapshots leave it (§4.3, §6.1).
/// Read-only: no save/remove/commit calls exist anywhere in the app.
actor EventKitCalendarRepository: CalendarRepository {
    private let store = EKEventStore()

    nonisolated func authorization() async -> CalendarAuthorization {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    static func map(_ s: EKAuthorizationStatus) -> CalendarAuthorization {
        switch s {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        @unknown default: .denied
        }
    }

    func requestAccess() async -> CalendarAuthorization {
        // Never re-prompt after a denial (§6.1): only request when undetermined.
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else {
            return Self.map(EKEventStore.authorizationStatus(for: .event))
        }
        _ = try? await store.requestFullAccessToEvents()
        store.reset()
        return Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    func calendars() async throws -> [CalendarSnapshot] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarRepositoryError.notAuthorized(Self.map(EKEventStore.authorizationStatus(for: .event)))
        }
        return store.calendars(for: .event).map { c in
            CalendarSnapshot(id: c.calendarIdentifier, title: c.title, sourceID: c.source?.sourceIdentifier ?? "local",
                             sourceTitle: c.source?.title ?? "On My Mac", color: Self.color(c.cgColor))
        }
    }

    func occurrences(in range: DateInterval, calendarIDs: Set<String>) async throws -> [CalendarOccurrenceSnapshot] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarRepositoryError.notAuthorized(Self.map(EKEventStore.authorizationStatus(for: .event)))
        }
        let cals = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return [] }
        // Bounded predicate: EventKit expands recurrences within the range (§6.2).
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: cals)
        return store.events(matching: predicate).map(Self.snapshot)
    }

    nonisolated func changes() -> AsyncStream<CalendarChange> {
        AsyncStream { cont in
            let token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: nil) { _ in
                cont.yield(.storeChanged)
            }
            nonisolated(unsafe) let t = token
            cont.onTermination = { _ in NotificationCenter.default.removeObserver(t) }
        }
    }

    static func color(_ cg: CGColor?) -> RGBAColor {
        guard let cg, let c = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return .gray }
        return RGBAColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }

    static func snapshot(_ e: EKEvent) -> CalendarOccurrenceSnapshot {
        var rsvp: RSVPStatus = .none
        if let me = e.attendees?.first(where: { $0.isCurrentUser }) {
            switch me.participantStatus {
            case .accepted: rsvp = .accepted
            case .declined: rsvp = .declined
            case .tentative: rsvp = .tentative
            case .pending, .unknown, .delegated, .inProcess: rsvp = .pending
            case .completed: rsvp = .accepted
            @unknown default: rsvp = .pending
            }
        }
        if e.organizer?.isCurrentUser == true { rsvp = .organizer }
        return CalendarOccurrenceSnapshot(
            sourceID: e.calendar.source?.sourceIdentifier ?? "local", calendarID: e.calendar.calendarIdentifier,
            calendarTitle: e.calendar.title, calendarColor: color(e.calendar.cgColor),
            calendarItemIdentifier: e.calendarItemIdentifier, externalIdentifier: e.calendarItemExternalIdentifier,
            eventIdentifier: e.eventIdentifier ?? e.calendarItemIdentifier, title: e.title ?? "Untitled",
            start: e.startDate, end: e.endDate ?? e.startDate, timeZoneID: e.timeZone?.identifier,
            originalOccurrenceDate: e.occurrenceDate, isDetached: e.isDetached, isRecurring: e.hasRecurrenceRules || e.isDetached,
            isAllDay: e.isAllDay, isCancelled: e.status == .canceled, rsvp: rsvp, url: e.url?.absoluteString,
            location: e.location, notes: e.notes, organizer: e.organizer?.name, lastModified: e.lastModifiedDate)
    }
}

/// Synthetic calendar for UI tests and screenshots (`-UseFakeCalendar YES`). Never touches the real calendar (§23.1).
actor FakeCalendarRepository: CalendarRepository {
    private var failNext = false

    func authorization() async -> CalendarAuthorization { .fullAccess }
    func requestAccess() async -> CalendarAuthorization { .fullAccess }

    func calendars() async throws -> [CalendarSnapshot] {
        [CalendarSnapshot(id: "fake-work", title: "Work", sourceID: "fake-src", sourceTitle: "Synthetic", color: RGBAColor(red: 0.2, green: 0.75, blue: 0.35)),
         CalendarSnapshot(id: "fake-team", title: "Team", sourceID: "fake-src", sourceTitle: "Synthetic", color: RGBAColor(red: 0.3, green: 0.5, blue: 0.95))]
    }

    func setFailNext() { failNext = true }

    func occurrences(in range: DateInterval, calendarIDs: Set<String>) async throws -> [CalendarOccurrenceSnapshot] {
        if failNext { failNext = false; throw CalendarRepositoryError.fetchFailed("synthetic") }
        let cal = Calendar.current
        var out: [CalendarOccurrenceSnapshot] = []
        var day = cal.startOfDay(for: range.start)
        while day < range.end {
            for (i, f) in Self.fixture.enumerated() {
                let start = cal.date(bySettingHour: f.h, minute: f.m, second: 0, of: day)!
                let end = start.addingTimeInterval(Double(f.dur) * 60)
                guard end > range.start, start < range.end else { continue }
                let link: String? = switch f.provider {
                case "zoom": "https://example.zoom.us/j/12345678\(String(format: "%02d", i))?pwd=synthetic"
                case "meet": "https://meet.google.com/abc-defg-hi\(["j", "k", "m", "n"][i % 4])"
                case "teams": "https://teams.microsoft.com/l/meetup-join/19%3ameeting_synthetic\(i)%40thread.v2/0?context=%7b%7d"
                default: nil
                }
                out.append(CalendarOccurrenceSnapshot(
                    sourceID: "fake-src", calendarID: i % 3 == 0 ? "fake-team" : "fake-work", calendarTitle: "Work",
                    calendarColor: i % 3 == 0 ? RGBAColor(red: 0.3, green: 0.5, blue: 0.95) : RGBAColor(red: 0.2, green: 0.75, blue: 0.35),
                    calendarItemIdentifier: "fake-\(i)", externalIdentifier: "fake-ext-\(i)", eventIdentifier: "fake-ev-\(i)",
                    title: f.title, start: start, end: end, timeZoneID: TimeZone.current.identifier, originalOccurrenceDate: f.recurring ? start : nil,
                    isRecurring: f.recurring, rsvp: f.rsvp, url: f.provider == "zoom" ? link : nil,
                    location: f.provider == "meet" ? link : nil, notes: f.provider == "teams" ? "Join here: \(link!)" : nil))
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return out.filter { calendarIDs.isEmpty || calendarIDs.contains($0.calendarID) }
    }

    nonisolated func changes() -> AsyncStream<CalendarChange> { AsyncStream { _ in } }

    struct F { var h: Int; var m: Int; var dur: Int; var title: String; var provider: String?; var recurring: Bool; var rsvp: RSVPStatus }
    static let fixture: [F] = [
        F(h: 9, m: 45, dur: 15, title: "Daily | Search Funnel", provider: "zoom", recurring: true, rsvp: .accepted),
        F(h: 10, m: 0, dur: 30, title: "Prep for on-call refresh session", provider: "meet", recurring: false, rsvp: .accepted),
        F(h: 11, m: 0, dur: 30, title: "Monthly Platform Maintenance", provider: "teams", recurring: true, rsvp: .accepted),
        F(h: 13, m: 0, dur: 60, title: "Hybrid Heroes Bi-Weekly Sync", provider: "zoom", recurring: true, rsvp: .tentative),
        F(h: 15, m: 15, dur: 45, title: "Product & Tech Weekly", provider: "meet", recurring: true, rsvp: .accepted),
        F(h: 16, m: 0, dur: 30, title: "Leasing AB Test Set Up", provider: nil, recurring: false, rsvp: .accepted),
        F(h: 16, m: 30, dur: 30, title: "Post-incident review for SIM-0000 synthetic ticket with a long title", provider: "zoom", recurring: false, rsvp: .declined),
    ]
}
