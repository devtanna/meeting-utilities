import AppKit
import Combine
import Foundation
import MeetingCore
import MeetingData

/// Calendar state shared by both presentation modes: snapshots, identity mapping, freshness (§6.2).
@MainActor
final class CalendarEngine: ObservableObject {
    @Published private(set) var authorization: CalendarAuthorization = .notDetermined
    @Published private(set) var calendars: [CalendarSnapshot] = []
    @Published private(set) var agendaItems: [AgendaItem] = []        // viewed days
    @Published private(set) var plannerItems: [AgendaItem] = []       // rolling 48 h
    @Published private(set) var freshness = CalendarFreshness()
    @Published var viewedDay: Date = Calendar.current.startOfDay(for: Date())
    @Published private(set) var resolved: [String: ResolvedOccurrence] = [:]
    @Published private(set) var lastError: AppError?

    let repository: any CalendarRepository
    private let store: MeetingStore
    private let settings: AppSettings
    private let linkExtractor: LinkExtractor
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var backstop: Timer?
    private var midnightTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var changeTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    var onUpdate: (() -> Void)?

    init(repository: any CalendarRepository, store: MeetingStore, settings: AppSettings, linkExtractor: LinkExtractor) {
        self.repository = repository
        self.store = store
        self.settings = settings
        self.linkExtractor = linkExtractor
    }

    func start() {
        changeTask = Task { [weak self] in
            guard let stream = self?.repository.changes() else { return }
            for await _ in stream { self?.scheduleRefresh(reason: "store_changed") }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(reason: "wake_or_session") }
            })
        }
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if Calendar.current.isDate(self.viewedDay, inSameDayAs: Date().addingTimeInterval(-86400)) { self.viewedDay = Calendar.current.startOfDay(for: Date()) }
                    self.refresh(reason: "clock")
                }
            })
        }
        // Conservative 15-minute freshness backstop, not a polling loop (§6.2).
        backstop = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(reason: "backstop") }
        }
        backstop?.tolerance = 60
        settings.$selectedCalendarIDs.dropFirst().removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.refresh(reason: "selection") }
        }.store(in: &cancellables)
        $viewedDay.dropFirst().removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.refresh(reason: "navigation") }
        }.store(in: &cancellables)
        refresh(reason: "launch")
    }

    var isToday: Bool { Calendar.current.isDateInToday(viewedDay) }

    func requestAccess() async {
        authorization = await repository.requestAccess()
        AppServices.shared?.windows.refocusAfterSystemPrompt()
        if authorization.canRead {
            if settings.selectedCalendarIDs.isEmpty, let cals = try? await repository.calendars() {
                calendars = cals
            }
            refresh(reason: "authorized")
        }
    }

    /// Debounce bursts of EKEventStoreChanged by ~300 ms (§6.2).
    func scheduleRefresh(reason: String) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refresh(reason: reason)
        }
    }

    /// Refresh if the snapshot is older than a minute (opening the agenda, §6.2).
    func refreshIfOld() {
        if let last = freshness.lastSuccess, Date().timeIntervalSince(last) < 60 { return }
        refresh(reason: "open_agenda")
    }

    func refresh(reason: String) {
        generation += 1
        let gen = generation
        let selected = settings.selectedCalendarIDs
        let day = viewedDay
        Task { [weak self] in
            guard let self else { return }
            let signpost = Log.signposter.beginInterval("calendar.refresh")
            defer { Log.signposter.endInterval("calendar.refresh", signpost) }
            let auth = await repository.authorization()
            self.authorization = auth
            guard auth.canRead else {
                // Revocation clears transient snapshots and future actions; saved notes remain (§19.3).
                self.calendars = []; self.agendaItems = []; self.plannerItems = []; self.resolved = [:]
                self.freshness = CalendarFreshness(generation: gen, lastSuccess: nil, state: .stale(reason: "not_authorized"))
                self.lastError = auth == .notDetermined ? nil : AppError(.calendarDenied)
                self.onUpdate?()
                return
            }
            do {
                let cals = try await repository.calendars()
                let available = Set(cals.map(\.id))
                let missing = selected.subtracting(available)
                let ids = selected.intersection(available)
                let now = Date()
                let agendaRange = DateInterval(start: day, end: Calendar.current.date(byAdding: .day, value: 2, to: day)!)
                let plannerRange = FetchRanges.planner(now: now)
                let a = try await repository.occurrences(in: agendaRange, calendarIDs: ids)
                let p = try await repository.occurrences(in: plannerRange, calendarIDs: ids)
                var byID: [String: CalendarOccurrenceSnapshot] = [:]
                for e in a + p { byID[e.id] = e }
                let resolvedMap = try await store.resolveAll(Array(byID.values), now: now)
                guard gen == self.generation else { return } // discard stale generation
                // Confirmed disappearance in a healthy refresh marks occurrences missing; content kept.
                let seen = Set(resolvedMap.values.map(\.occurrence.id))
                try? await store.markMissing(in: plannerRange, seenOccurrenceIDs: seen, calendarIDs: ids)
                // Link overrides: occurrence first, then series. One query per scope instead of two per event.
                let occOverrides = (try? await store.settings(LinkOverride.self, scope: "occurrence", ids: resolvedMap.values.map(\.occurrence.id.uuidString), key: "linkOverride")) ?? [:]
                let nbOverrides = (try? await store.settings(LinkOverride.self, scope: "notebook", ids: resolvedMap.values.map(\.notebook.id.uuidString), key: "linkOverride")) ?? [:]
                var items: [String: AgendaItem] = [:]
                for (id, e) in byID {
                    let candidates = linkExtractor.candidates(for: e)
                    var override: LinkOverride?
                    if let r = resolvedMap[id] {
                        override = occOverrides[r.occurrence.id.uuidString] ?? nbOverrides[r.notebook.id.uuidString]
                    }
                    let (primary, _) = LinkSelection.choose(candidates: candidates, override: override)
                    items[id] = AgendaItem(event: e, primaryLink: primary, alternativeLinks: candidates.filter { $0 != primary },
                                           isDismissed: resolvedMap[id]?.occurrence.dismissed ?? false)
                }
                self.calendars = cals
                self.resolved = resolvedMap
                self.agendaItems = a.compactMap { items[$0.id] }
                self.plannerItems = p.compactMap { items[$0.id] }
                self.freshness = CalendarFreshness(generation: gen, lastSuccess: now, state: .fresh, missingCalendarIDs: missing)
                self.lastError = nil
                Log.calendar.info("refresh ok gen=\(gen, privacy: .public) reason=\(reason, privacy: .public) events=\(byID.count, privacy: .public)")
            } catch {
                guard gen == self.generation else { return }
                // A failed refresh never becomes an authoritative empty result (§6.2).
                self.freshness.state = .stale(reason: "fetch_failed")
                self.freshness.generation = gen
                self.lastError = AppError(.calendarStale)
                Log.calendar.error("refresh failed gen=\(gen, privacy: .public)")
            }
            self.onUpdate?()
        }
    }

    // MARK: Queries

    func occurrenceID(for item: AgendaItem) -> UUID? { resolved[item.event.id]?.occurrence.id }
    func resolvedOccurrence(for item: AgendaItem) -> ResolvedOccurrence? { resolved[item.event.id] }

    func item(occurrenceID: UUID) -> AgendaItem? {
        guard let key = resolved.first(where: { $0.value.occurrence.id == occurrenceID })?.key else { return nil }
        return (agendaItems + plannerItems).first { $0.event.id == key }
    }

    var visibleItems: [AgendaItem] { AgendaBuilder.applyFilters(agendaItems, filters: settings.filters) }

    var sections: [AgendaSection] {
        let cal = Calendar.current
        return AgendaBuilder.sections(visibleItems, days: [viewedDay, cal.date(byAdding: .day, value: 1, to: viewedDay)!])
    }

    /// Current/next item for the compact status; always based on today, independent of navigation.
    func focusItem(now: Date = Date()) -> AgendaItem? {
        AgendaBuilder.focusItem(AgendaBuilder.applyFilters(plannerItems + agendaItems.filter { Calendar.current.isDateInToday($0.event.start) }, filters: settings.filters), now: now)
    }

    /// Meeting shown in the compact menu-bar status (respects the display options).
    func menuBarItem(now: Date = Date()) -> AgendaItem? {
        let items = AgendaBuilder.applyFilters(plannerItems + agendaItems.filter { Calendar.current.isDateInToday($0.event.start) }, filters: settings.filters)
        return AgendaBuilder.menuBarItem(items, now: now,
                                         lookaheadMinutes: settings.menuBarLookahead < 0 ? nil : settings.menuBarLookahead,
                                         hideCurrentAfterMinutes: settings.hideCurrentAfter < 0 ? nil : settings.hideCurrentAfter)
    }

    /// What "Join" acts on by default: the meeting shown in the menu bar, else the current/next meeting today.
    func joinTarget(now: Date = Date()) -> AgendaItem? { menuBarItem(now: now) ?? focusItem(now: now) }

    func dismiss(_ item: AgendaItem, _ dismissed: Bool) async {
        guard let id = occurrenceID(for: item) else { return }
        try? await store.setDismissed(id, dismissed)
        refresh(reason: "dismiss")
    }
}
