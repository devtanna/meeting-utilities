import AppKit
import Combine
import Foundation
import KeyboardShortcuts
import MeetingCore

enum PresentationMode: String, CaseIterable, Codable, Sendable {
    case menuBar, notch
    var label: String { self == .menuBar ? "Menu bar" : "Notch" }
}

enum TimeFormatPreference: String, CaseIterable, Codable, Sendable {
    case system, twelveHour, twentyFourHour
    var label: String {
        switch self { case .system: "Follow macOS"; case .twelveHour: "12-hour"; case .twentyFourHour: "24-hour" }
    }
}

/// Typed UserDefaults wrapper for small global preferences (§2.1). Per-series/occurrence overrides live in SQLite.
@MainActor
final class AppSettings: ObservableObject {
    private let d: UserDefaults

    @Published var onboardingComplete: Bool { didSet { d.set(onboardingComplete, forKey: "onboardingComplete") } }
    @Published var presentation: PresentationMode { didSet { d.set(presentation.rawValue, forKey: "presentation") } }
    @Published var statusTitleLength: StatusTitleLength { didSet { d.set(statusTitleLength.rawValue, forKey: "statusTitleLength") } }
    @Published var compactStatus: CompactStatusContent { didSet { d.set(compactStatus.rawValue, forKey: "compactStatus") } }
    @Published var notchHoverExpands: Bool { didSet { d.set(notchHoverExpands, forKey: "notchHoverExpands") } }
    @Published var notchDisplayID: UInt32 { didSet { d.set(Int(notchDisplayID), forKey: "notchDisplayID") } }
    @Published var selectedCalendarIDs: Set<String> { didSet { d.set(Array(selectedCalendarIDs), forKey: "selectedCalendarIDs") } }
    @Published var filters: AgendaFilters { didSet { save(filters, "filters") } }
    @Published var timeFormat: TimeFormatPreference { didSet { d.set(timeFormat.rawValue, forKey: "timeFormat") } }
    @Published var showQuarterInAgenda: Bool { didSet { d.set(showQuarterInAgenda, forKey: "showQuarterInAgenda") } }
    /// Minutes before start that an upcoming meeting appears in the menu bar; -1 = always.
    @Published var menuBarLookahead: Int { didSet { d.set(menuBarLookahead, forKey: "menuBarLookahead") } }
    /// Minutes after start that a running meeting is hidden from the menu bar; -1 = keep until it ends.
    @Published var hideCurrentAfter: Int { didSet { d.set(hideCurrentAfter, forKey: "hideCurrentAfter") } }
    /// Calendar app used by "Open in…".
    @Published var calendarAppBundleID: String { didSet { d.set(calendarAppBundleID, forKey: "calendarAppBundleID") } }

    @Published var remindersEnabled: Bool { didSet { d.set(remindersEnabled, forKey: "remindersEnabled") } }
    @Published var reminderOffsets: Set<ReminderOffset> { didSet { d.set(reminderOffsets.map(\.rawValue), forKey: "reminderOffsets") } }
    @Published var reminderPreview: ReminderPreview { didSet { d.set(reminderPreview.rawValue, forKey: "reminderPreview") } }
    @Published var immediateReminderForLateImports: Bool { didSet { d.set(immediateReminderForLateImports, forKey: "immediateReminder") } }

    @Published var autoJoinGlobal: Bool { didSet { d.set(autoJoinGlobal, forKey: "autoJoinGlobal") } }
    @Published var openPreferences: [MeetingProvider: OpenPreference] { didSet { save(openPreferences, "openPreferences") } }

    @Published var autoFocusEnabled: Bool { didSet { d.set(autoFocusEnabled, forKey: "autoFocusEnabled") } }
    @Published var focusShortcutIdentifier: String? { didSet { d.set(focusShortcutIdentifier, forKey: "focusShortcutIdentifier") } }
    @Published var focusShortcutName: String? { didSet { d.set(focusShortcutName, forKey: "focusShortcutName") } }
    @Published var focusShortcutTested: Bool { didSet { d.set(focusShortcutTested, forKey: "focusShortcutTested") } }

    @Published var automationMode: AutomationMode { didSet { d.set(automationMode.rawValue, forKey: "automationMode") } }
    @Published var automationOptIn: Bool { didSet { d.set(automationOptIn, forKey: "automationOptIn") } }
    @Published var microphoneUID: String? { didSet { d.set(microphoneUID, forKey: "microphoneUID") } }
    @Published var microphoneTested: Bool { didSet { d.set(microphoneTested, forKey: "microphoneTested") } }
    @Published var systemAudioTested: Bool { didSet { d.set(systemAudioTested, forKey: "systemAudioTested") } }
    @Published var voiceProcessing: Bool { didSet { d.set(voiceProcessing, forKey: "voiceProcessing") } }
    @Published var deferSummariesOnLowPower: Bool { didSet { d.set(deferSummariesOnLowPower, forKey: "deferSummariesOnLowPower") } }

    @Published var talktrackFontSize: Double { didSet { d.set(talktrackFontSize, forKey: "talktrackFontSize") } }
    @Published var talktrackLineSpacing: Double { didSet { d.set(talktrackLineSpacing, forKey: "talktrackLineSpacing") } }
    @Published var talktrackSpeed: Double { didSet { d.set(talktrackSpeed, forKey: "talktrackSpeed") } }
    @Published var talktrackPinned: Bool { didSet { d.set(talktrackPinned, forKey: "talktrackPinned") } }

    // Sounds
    @Published var soundVolume: Double { didSet { d.set(soundVolume, forKey: "soundVolume") } }
    @Published var meetingSoundEnabled: Bool { didSet { d.set(meetingSoundEnabled, forKey: "meetingSoundEnabled") } }
    @Published var meetingSound: String { didSet { d.set(meetingSound, forKey: "meetingSound") } }
    @Published var meetingSoundLead: Int { didSet { d.set(meetingSoundLead, forKey: "meetingSoundLead") } }
    @Published var intervalSoundEnabled: Bool { didSet { d.set(intervalSoundEnabled, forKey: "intervalSoundEnabled") } }
    @Published var intervalSound: String { didSet { d.set(intervalSound, forKey: "intervalSound") } }
    @Published var intervalMinutes: Int { didSet { d.set(intervalMinutes, forKey: "intervalMinutes") } }
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    @Published var intervalWindow: ChimePlanner.ChimeWindow { didSet { save(intervalWindow, "intervalWindow") } }

    @Published var updatePreferenceAsked: Bool { didSet { d.set(updatePreferenceAsked, forKey: "updatePreferenceAsked") } }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        func get<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: key), let v = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return v
        }
        onboardingComplete = d.bool(forKey: "onboardingComplete")
        presentation = PresentationMode(rawValue: d.string(forKey: "presentation") ?? "") ?? .menuBar
        statusTitleLength = StatusTitleLength(rawValue: d.string(forKey: "statusTitleLength") ?? "") ?? .medium
        compactStatus = CompactStatusContent(rawValue: d.string(forKey: "compactStatus") ?? "") ?? .meeting
        notchHoverExpands = d.bool(forKey: "notchHoverExpands")
        notchDisplayID = UInt32(d.integer(forKey: "notchDisplayID"))
        selectedCalendarIDs = Set(d.stringArray(forKey: "selectedCalendarIDs") ?? [])
        // Defaults: only meetings with a link, no all-day events.
        filters = get("filters", AgendaFilters(hideAllDay: true, hideLinkless: true))
        timeFormat = TimeFormatPreference(rawValue: d.string(forKey: "timeFormat") ?? "") ?? .system
        showQuarterInAgenda = d.object(forKey: "showQuarterInAgenda") as? Bool ?? true
        menuBarLookahead = d.object(forKey: "menuBarLookahead") as? Int ?? 15
        hideCurrentAfter = d.object(forKey: "hideCurrentAfter") as? Int ?? 15
        calendarAppBundleID = d.string(forKey: "calendarAppBundleID") ?? CalendarApps.apple
        remindersEnabled = d.bool(forKey: "remindersEnabled")
        let offs = (d.array(forKey: "reminderOffsets") as? [Int])?.compactMap(ReminderOffset.init(rawValue:)) ?? [.ten]
        reminderOffsets = Set(offs)
        reminderPreview = ReminderPreview(rawValue: d.string(forKey: "reminderPreview") ?? "") ?? .meetingTitle
        immediateReminderForLateImports = d.bool(forKey: "immediateReminder")
        autoJoinGlobal = d.bool(forKey: "autoJoinGlobal")
        openPreferences = get("openPreferences", [:])
        autoFocusEnabled = d.bool(forKey: "autoFocusEnabled")
        focusShortcutIdentifier = d.string(forKey: "focusShortcutIdentifier")
        focusShortcutName = d.string(forKey: "focusShortcutName")
        focusShortcutTested = d.bool(forKey: "focusShortcutTested")
        automationMode = AutomationMode(rawValue: d.string(forKey: "automationMode") ?? "") ?? .off
        automationOptIn = d.bool(forKey: "automationOptIn")
        microphoneUID = d.string(forKey: "microphoneUID")
        microphoneTested = d.bool(forKey: "microphoneTested")
        systemAudioTested = d.bool(forKey: "systemAudioTested")
        voiceProcessing = d.bool(forKey: "voiceProcessing")
        deferSummariesOnLowPower = d.object(forKey: "deferSummariesOnLowPower") as? Bool ?? true
        talktrackFontSize = d.object(forKey: "talktrackFontSize") as? Double ?? 24
        talktrackLineSpacing = d.object(forKey: "talktrackLineSpacing") as? Double ?? 6
        talktrackSpeed = d.object(forKey: "talktrackSpeed") as? Double ?? 24
        talktrackPinned = d.object(forKey: "talktrackPinned") as? Bool ?? true
        updatePreferenceAsked = d.bool(forKey: "updatePreferenceAsked")
        soundVolume = d.object(forKey: "soundVolume") as? Double ?? 0.6
        meetingSoundEnabled = d.bool(forKey: "meetingSoundEnabled")
        meetingSound = d.string(forKey: "meetingSound") ?? "mu.heads-up"
        meetingSoundLead = d.object(forKey: "meetingSoundLead") as? Int ?? 2
        intervalSoundEnabled = d.bool(forKey: "intervalSoundEnabled")
        intervalSound = d.string(forKey: "intervalSound") ?? "mu.soft-beep"
        intervalMinutes = d.object(forKey: "intervalMinutes") as? Int ?? 30
        showInDock = d.bool(forKey: "showInDock")
        intervalWindow = get("intervalWindow", ChimePlanner.ChimeWindow.workdays)
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        d.set(try? JSONEncoder().encode(v), forKey: key)
    }

    var sourcesTested: Bool { microphoneTested && systemAudioTested }

    func openPreference(_ p: MeetingProvider) -> OpenPreference { openPreferences[p] ?? .defaultBrowser }

    /// Erase-all also resets preferences (§18.4: stored per-meeting settings).
    func resetAll() {
        if let id = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: id) }
    }
}

/// Global shortcuts have no defaults: the user records them in Settings › General if they want them.
extension KeyboardShortcuts.Name {
    static let toggleAgenda = Self("toggleAgenda")
    static let joinMeeting = Self("joinMeeting")
    static let openNotes = Self("openNotes")
    static let toggleTalktrack = Self("toggleTalktrack")
    static let hideTalktrack = Self("hideTalktrack")
    static let openSettings = Self("openSettings")

    static let all: [Self] = [.toggleAgenda, .joinMeeting, .openNotes, .toggleTalktrack, .hideTalktrack, .openSettings]

    /// Earlier builds shipped defaults. Clear those once (only if still equal to the old default, so a shortcut the
    /// user chose themselves is kept).
    @MainActor static func removeLegacyDefaults() {
        let key = "shortcutDefaultsRemovedV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let legacy: [(Self, KeyboardShortcuts.Shortcut)] = [
            (.toggleAgenda, .init(.m, modifiers: [.command, .option])),
            (.joinMeeting, .init(.j, modifiers: [.command, .option])),
            (.openNotes, .init(.n, modifiers: [.command, .option])),
            (.toggleTalktrack, .init(.t, modifiers: [.command, .option])),
            (.hideTalktrack, .init(.h, modifiers: [.command, .option, .shift])),
        ]
        for (name, old) in legacy where KeyboardShortcuts.getShortcut(for: name) == old {
            KeyboardShortcuts.setShortcut(nil, for: name)
        }
        UserDefaults.standard.set(true, forKey: key)
    }
}

/// Calendar apps "Open in…" can use; only installed ones are offered.
enum CalendarApps {
    static let apple = "com.apple.iCal"
    static let known: [String] = [apple, "com.flexibits.fantastical2.mac", "com.busymac.busycal3", "com.busymac.busycal-setapp",
                                  "com.cron.electron", "com.microsoft.Outlook", "com.readdle.CalendarsMac"]

    struct App: Identifiable, Hashable { var id: String; var name: String; var url: URL }

    @MainActor static func installed() -> [App] {
        known.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return App(id: id, name: id == apple ? "Calendar" : name, url: url)
        }
    }

    @MainActor static func name(_ id: String) -> String { installed().first { $0.id == id }?.name ?? "Calendar" }
}
