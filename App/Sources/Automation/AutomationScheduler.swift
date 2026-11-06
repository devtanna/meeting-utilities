import AppKit
import Foundation
import MeetingCore
import MeetingData

/// One reschedulable timer for the next auto-join boundary, plus reminder reconciliation (§11, §D1).
/// No 1-second polling; recomputed on calendar change, wake, clock and time-zone changes.
@MainActor
final class AutomationScheduler: ObservableObject {
    @Published var conflictChoice: [AgendaItem] = []        // overlapping eligible meetings: user chooses (§11.1)
    @Published private(set) var nextBoundary: Date?

    private let calendar: CalendarEngine
    private let store: MeetingStore
    private let settings: AppSettings
    private let notifications: NotificationController
    private let coordinator: MeetingCoordinator
    private var timer: Timer?
    private var armedAt = Date()
    private var observers: [NSObjectProtocol] = []
    private var candidates: [UUID: (AutoJoinCandidate, AgendaItem)] = [:]

    init(calendar: CalendarEngine, store: MeetingStore, settings: AppSettings, notifications: NotificationController, coordinator: MeetingCoordinator) {
        self.calendar = calendar; self.store = store; self.settings = settings; self.notifications = notifications; self.coordinator = coordinator
        let ws = NSWorkspace.shared.notificationCenter
        // After sleep the plan is re-armed: starts missed while asleep never trigger catch-up (§11.1).
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.armedAt = Date(); self?.replan() }
            })
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.armedAt = Date(); self?.replan() }
            })
        }
    }

    func autoJoinOverride(occurrenceID: UUID, notebookID: UUID) async -> (Bool?, Bool?) {
        let o = try? await store.setting(Bool.self, scope: "occurrence", id: occurrenceID.uuidString, key: "autoJoin")
        let s = try? await store.setting(Bool.self, scope: "notebook", id: notebookID.uuidString, key: "autoJoin")
        return (o ?? nil, s ?? nil)
    }

    func replan() {
        Task {
            let now = Date()
            let ledger = (try? await store.actionStates(kind: .autoJoin)) ?? [:]
            var cands: [UUID: (AutoJoinCandidate, AgendaItem)] = [:]
            var plannable: [PlannableOccurrence] = []
            for item in calendar.plannerItems {
                guard let r = calendar.resolvedOccurrence(for: item) else { continue }
                let (o, s) = await autoJoinOverride(occurrenceID: r.occurrence.id, notebookID: r.notebook.id)
                let resolved = ScopedValue.resolve(occurrence: o, series: s, global: settings.autoJoinGlobal)
                let linkCount = item.primaryLink == nil ? 0 : 1
                let c = AutoJoinCandidate(occurrenceID: r.occurrence.id, start: item.event.start, end: item.event.end, autoJoinEnabled: resolved.value,
                                          explicitlyIncluded: resolved.inheritedFrom != .global && resolved.value, linkCount: linkCount,
                                          isCancelled: item.event.isCancelled, rsvp: item.event.rsvp, isDismissed: item.isDismissed,
                                          isAllDay: item.event.isAllDay, ledgerState: ledger[r.occurrence.id])
                cands[r.occurrence.id] = (c, item)
                plannable.append(PlannableOccurrence(occurrenceID: r.occurrence.id, title: item.event.title, start: item.event.start, end: item.event.end,
                                                     isAllDay: item.event.isAllDay, isCancelled: item.event.isCancelled, rsvp: item.event.rsvp,
                                                     isDismissed: item.isDismissed, hasLink: linkCount > 0, linkCount: linkCount))
            }
            candidates = cands
            // Reminders.
            if settings.remindersEnabled && calendar.freshness.state != .neverLoaded {
                let tf = DateFormatter(); tf.timeStyle = .short; tf.dateStyle = .none
                let desired = ReminderPlanner.plan(occurrences: plannable, offsets: settings.reminderOffsets, now: now, preview: settings.reminderPreview,
                                                   timeFormatter: { tf.string(from: $0) })
                await notifications.reconcile(desired)
            } else if !settings.remindersEnabled {
                notifications.removeAll()
            }
            // Auto-join timer: exactly one, for the next boundary.
            timer?.invalidate()
            nextBoundary = AutoJoinPlanner.nextBoundary(candidates: cands.values.map(\.0), now: now)
            if let b = nextBoundary {
                timer = Timer.scheduledTimer(withTimeInterval: max(0.1, b.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fire() }
                }
                timer?.tolerance = 1
            }
        }
    }

    private func fire() {
        let now = Date()
        let decision = AutoJoinPlanner.decide(candidates: candidates.values.map(\.0), now: now, armedAt: armedAt,
                                              calendarFresh: calendar.freshness.permitsAutomation, activeCaptureOccurrence: coordinator.isCapturing ? coordinator.active?.occurrenceID : nil)
        switch decision {
        case .join(let id):
            guard let (c, item) = candidates[id] else { break }
            Task { await autoJoin(id, plannedAt: c.start, item: item) }
        case .askUser(let ids):
            conflictChoice = ids.compactMap { candidates[$0]?.1 }
            NSApp.activate()
        case .suppressedByActiveCapture(let id):
            if let item = candidates[id]?.1 { conflictChoice = [item]; coordinator.banner = "Auto join paused because another meeting is being transcribed." }
        case .suppressedStaleCalendar:
            coordinator.banner = AppErrorCode.calendarStale.message
        case .nothing:
            break
        }
        replan()
    }

    /// Reserve-then-act in the durable ledger (§11.2).
    private func autoJoin(_ id: UUID, plannedAt: Date, item: AgendaItem) async {
        do {
            try await store.reserveAction(occurrenceID: id, kind: .autoJoin, plannedAt: plannedAt)
        } catch {
            return // already reserved by another path: never a second automatic open
        }
        let ok = await coordinator.join(item, source: .automatic)
        try? await store.finishAction(occurrenceID: id, kind: .autoJoin, state: ok ? .succeeded : .failed, resultCode: ok ? "open_requested" : "open_failed")
        replan()
    }

    /// User picked one of several simultaneous meetings. Explicit choice, so it goes through the manual path.
    func choose(_ item: AgendaItem?) {
        let options = conflictChoice
        conflictChoice = []
        Task {
            for o in options {
                if let id = calendar.occurrenceID(for: o) {
                    try? await store.reserveAction(occurrenceID: id, kind: .autoJoin, plannedAt: o.event.start)
                    try? await store.finishAction(occurrenceID: id, kind: .autoJoin, state: o == item ? .succeeded : .failed, resultCode: o == item ? "user_chose" : "user_skipped")
                }
            }
            if let item { _ = await coordinator.join(item, source: .manual) }
        }
    }
}
