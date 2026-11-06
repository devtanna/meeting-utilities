import AppKit
import Combine
import Foundation
import KeyboardShortcuts
import MeetingCore
import MeetingData
import ServiceManagement

/// App-wide service container. Created once; presentation modes share it, so switching mode never recreates
/// the calendar store, interrupts capture, or resets notes (§5.3).
@MainActor
final class AppServices: ObservableObject {
    static var shared: AppServices!

    let settings: AppSettings
    let appSupport: URL
    let database: AppDatabase?
    let store: MeetingStore!
    let databaseError: AppError?
    let entitlements: FeatureEntitlementProvider = AllFeaturesEntitlementProvider()
    let linkExtractor = LinkExtractor()
    let calendar: CalendarEngine
    let opener: LinkOpener
    let notifications: NotificationController
    let focusRunner: FocusShortcutRunner
    let models: ModelManager
    let inference: InferenceClient
    let coordinator: MeetingCoordinator
    let summaries: SummaryCoordinator
    let scheduler: AutomationScheduler
    let updates: UpdateController
    let sounds: SoundScheduler
    lazy var windows = WindowRouter(services: self)
    lazy var presentation = PresentationManager(services: self)

    @Published var now = Date()
    @Published var quarter = QuarterCore.info(for: Date())
    private var clockTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let synthetic = UserDefaults.standard.bool(forKey: "UseFakeCalendar")
        if !synthetic { LegacyMigration.run() }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.devtanna.meetingutils"
        settings = AppSettings(defaults: synthetic ? UserDefaults(suiteName: bundleID + ".synthetic")! : .standard)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let real = base.appendingPathComponent(bundleID, isDirectory: true)
        // Synthetic-calendar runs (UI tests, screenshots) use a separate sandbox and never touch real notes.
        appSupport = UserDefaults.standard.bool(forKey: "UseFakeCalendar") ? real.appendingPathComponent("SyntheticSandbox", isDirectory: true) : real
        var db: AppDatabase?
        var dbError: AppError?
        do {
            db = try AppDatabase(directory: appSupport)
        } catch DatabaseOpenError.schemaTooNew {
            dbError = AppError(.databaseTooNew)
        } catch {
            dbError = AppError(.databaseUnwritable, detail: String(describing: type(of: error)))
        }
        if db == nil {
            // Keep the app usable (agenda, links) with a temporary store; never touch the unreadable file.
            db = try? AppDatabase.temporary()
        }
        database = db
        databaseError = dbError
        store = db.map(MeetingStore.init(database:))
        let useFake = UserDefaults.standard.bool(forKey: "UseFakeCalendar")
        let repo: any CalendarRepository = useFake ? FakeCalendarRepository() : EventKitCalendarRepository()
        if useFake && settings.selectedCalendarIDs.isEmpty { settings.selectedCalendarIDs = ["fake-work", "fake-team"] }
        calendar = CalendarEngine(repository: repo, store: store, settings: settings, linkExtractor: linkExtractor)
        opener = LinkOpener(settings: settings)
        notifications = NotificationController()
        let s = settings
        focusRunner = FocusShortcutRunner(identifierProvider: { MainActor.assumeIsolated { s.focusShortcutIdentifier } })
        models = ModelManager(appSupport: real) // model weights are shared, never meeting content
        inference = InferenceClient()
        coordinator = MeetingCoordinator(store: store, calendar: calendar, settings: settings, opener: opener, focus: focusRunner, models: models, client: inference)
        summaries = SummaryCoordinator(store: store, models: models, client: inference, settings: settings)
        coordinator.summaries = summaries
        scheduler = AutomationScheduler(calendar: calendar, store: store, settings: settings, notifications: notifications, coordinator: coordinator)
        updates = UpdateController(settings: settings)
        sounds = SoundScheduler(calendar: calendar, settings: settings)
        AppServices.shared = self
    }

    func start() {
        Task {
            _ = try? await store.recoverInterruptedSessions()     // never auto-restart recording after a crash (§10.6)
            try? await store.markInterruptedActionsAmbiguous()     // crash between reserve and open → ambiguous (§11.2)
        }
        summaries.isCaptureActive = { [weak self] in self?.coordinator.isCapturing ?? false }
        models.isInUse = { [weak self] id in
            guard let self else { return false }
            return (self.coordinator.isCapturing && self.models.entry(.speechToText)?.id == id)
        }
        calendar.onUpdate = { [weak self] in
            self?.scheduler.replan()
            self?.coordinator.calendarDidUpdate()
            self?.objectWillChange.send()
        }
        notifications.onAction = { [weak self] action, id in self?.handleNotification(action, id) }
        notifications.inAppPresentedOccurrences = { [weak self] in
            guard let self, self.presentation.isAgendaVisible, let f = self.calendar.focusItem(), let id = self.calendar.occurrenceID(for: f) else { return [] }
            return [id]
        }
        calendar.start()
        summaries.start()
        sounds.start()
        updates.start(canRelaunch: { [weak self] in self?.canRelaunchForUpdate ?? true })
        registerShortcuts()
        scheduleClock()
        settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.scheduler.replan() }
        }.store(in: &cancellables)
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Updates must not relaunch during capture, unsaved edits, or non-checkpointed jobs (§20.1).
    var canRelaunchForUpdate: Bool {
        !coordinator.isCapturing && !EditorRegistry.shared.hasUnsavedEdits && summaries.states.values.allSatisfy { $0 != .generating && $0 != .loadingModel }
    }

    /// Minute-level clock for countdowns: one timer at the next minute boundary or event start/end; never 1 Hz (§21.2).
    private func scheduleClock() {
        clockTimer?.invalidate()
        let next = CountdownFormatter.nextRefresh(after: Date(), items: calendar.plannerItems)
        clockTimer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow + 0.05), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        clockTimer?.tolerance = 2
    }

    func tick() {
        now = Date()
        quarter = QuarterCore.info(for: now)
        presentation.refreshCompact()
        scheduleClock()
    }

    private func registerShortcuts() {
        KeyboardShortcuts.Name.removeLegacyDefaults()
        KeyboardShortcuts.onKeyUp(for: .toggleAgenda) { [weak self] in self?.presentation.toggleAgenda() }
        KeyboardShortcuts.onKeyUp(for: .joinMeeting) { [weak self] in self?.joinFocused() }
        KeyboardShortcuts.onKeyUp(for: .openNotes) { [weak self] in
            guard let self, let item = self.calendar.focusItem() else { return }
            self.windows.openNotebook(for: item)
        }
        KeyboardShortcuts.onKeyUp(for: .toggleTalktrack) { [weak self] in self?.windows.toggleTalktrackForCurrent() }
        KeyboardShortcuts.onKeyUp(for: .hideTalktrack) { [weak self] in self?.windows.hideTalktrack() }
        KeyboardShortcuts.onKeyUp(for: .openSettings) { [weak self] in self?.windows.openSettings() }
    }

    /// Join shortcut: reveal a choice when overlapping meetings make the target ambiguous (§5.2).
    func joinFocused() {
        let targets = AgendaBuilder.ambiguousJoinTargets(calendar.plannerItems, now: Date())
        if targets.count > 1 {
            scheduler.conflictChoice = targets
            presentation.showAgenda()
            return
        }
        guard let item = targets.first ?? calendar.focusItem() else { return }
        Task { _ = await coordinator.join(item, source: .manual) }
    }

    private func handleNotification(_ action: String, _ occurrenceID: UUID) {
        switch action {
        case NotificationActionID.join:
            calendar.refresh(reason: "notification")
            guard let item = calendar.item(occurrenceID: occurrenceID) else {
                coordinator.banner = "That meeting is no longer in your calendar."
                return
            }
            Task { _ = await coordinator.join(item, source: .notification) }
        case NotificationActionID.dismiss:
            Task { try? await store.setDismissed(occurrenceID, true); calendar.refresh(reason: "dismiss") }
        default:
            windows.openNotebook(occurrenceID: occurrenceID)
        }
    }
}

/// Launch at login via SMAppService (§19.1, G4).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "On"
        case .requiresApproval: "Needs approval in System Settings › General › Login Items"
        case .notRegistered: "Off"
        case .notFound: "Unavailable for this build location"
        @unknown default: "Unknown"
        }
    }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { Log.app.error("login item change failed") }
    }
}

/// Tracks editors with pending (unsaved) edits for update/termination safety.
@MainActor
final class EditorRegistry {
    static let shared = EditorRegistry()
    private var dirty = Set<ObjectIdentifier>()
    private var flushers: [ObjectIdentifier: () async -> Void] = [:]
    var hasUnsavedEdits: Bool { !dirty.isEmpty }
    func setDirty(_ o: AnyObject, _ d: Bool) { if d { dirty.insert(ObjectIdentifier(o)) } else { dirty.remove(ObjectIdentifier(o)) } }
    func register(_ o: AnyObject, flush: @escaping () async -> Void) { flushers[ObjectIdentifier(o)] = flush }
    func unregister(_ o: AnyObject) { flushers.removeValue(forKey: ObjectIdentifier(o)); dirty.remove(ObjectIdentifier(o)) }
    func flushAll() async { for f in flushers.values { await f() } }
}
