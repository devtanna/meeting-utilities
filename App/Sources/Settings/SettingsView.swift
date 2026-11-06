import AppKit
import AVFoundation
import KeyboardShortcuts
import MeetingAudio
import MeetingCore
import MeetingData
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", calendars = "Calendars", agenda = "Agenda", reminders = "Reminders", sounds = "Sounds", automation = "Auto Join",
         focus = "Focus", transcription = "Transcription", models = "Models", data = "Data", updates = "Updates", diagnostics = "Diagnostics", about = "About"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .calendars: "calendar"
        case .agenda: "list.bullet"
        case .reminders: "bell.fill"
        case .sounds: "speaker.wave.2.fill"
        case .automation: "arrow.up.right.video.fill"
        case .focus: "moon.fill"
        case .transcription: "waveform"
        case .models: "cpu.fill"
        case .data: "externaldrive.fill"
        case .updates: "arrow.down.circle.fill"
        case .diagnostics: "stethoscope"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: Color(white: 0.45)
        case .calendars: .red
        case .agenda: .orange
        case .reminders: Color(red: 1, green: 0.27, blue: 0.4)
        case .sounds: Color(red: 1, green: 0.5, blue: 0.2)
        case .automation: .green
        case .focus: .indigo
        case .transcription: .purple
        case .models: .teal
        case .data: .blue
        case .updates: Color(red: 0.2, green: 0.55, blue: 1)
        case .diagnostics: Color(white: 0.5)
        case .about: Brand.green
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Presentation, startup and keyboard shortcuts."
        case .calendars: "Choose the calendars your agenda reads from."
        case .agenda: "Decide which events appear in your agenda."
        case .reminders: "Get a native notification before meetings start."
        case .sounds: "A sound before meetings and an optional interval chime."
        case .automation: "Open meeting links automatically and choose how they open."
        case .focus: "Turn on Do Not Disturb while you're in a meeting."
        case .transcription: "Transcribe meetings on this Mac. Audio is never saved."
        case .models: "Optional on-device models for transcripts and summaries."
        case .data: "Where your notes live, backups, and erasing data."
        case .updates: "Keep Meeting Utility up to date."
        case .diagnostics: "Self-tests and a redacted support report."
        case .about: "Version, licenses and model attribution."
        }
    }

    /// Extra words matched by the sidebar search.
    var keywords: String {
        switch self {
        case .general: "menu bar notch presentation login startup dock icon running shortcut hotkey quarter time format compact status"
        case .calendars: "calendar access permission accounts google exchange icloud"
        case .agenda: "filter all-day declined tentative dismissed link display options hide current event default application calendar app fantastical menu bar"
        case .reminders: "notification alert minutes"
        case .sounds: "sound chime beep volume interval before meeting alert audio"
        case .automation: "auto join open link browser zoom teams meet app"
        case .focus: "do not disturb dnd shortcut"
        case .transcription: "microphone system audio record transcript summary automatic test"
        case .models: "download parakeet qwen speech summary model disk"
        case .data: "erase delete backup export folder repair"
        case .updates: "sparkle version update"
        case .diagnostics: "support report self-test logs"
        case .about: "license notices attribution version"
        }
    }

    static let groups: [[SettingsTab]] = [
        [.general, .calendars, .agenda, .reminders, .sounds, .automation, .focus],
        [.transcription, .models],
        [.data, .updates, .diagnostics, .about],
    ]
}

@MainActor final class SettingsTabState: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var back: [SettingsTab] = []
    @Published var forward: [SettingsTab] = []

    func select(_ t: SettingsTab) {
        guard t != tab else { return }
        back.append(tab); forward.removeAll(); tab = t
    }
    func goBack() { guard let t = back.popLast() else { return }; forward.append(tab); tab = t }
    func goForward() { guard let t = forward.popLast() else { return }; back.append(tab); tab = t }
}

/// Sidebar + page layout: floating sidebar with search and coloured icons; pages with a large header and grouped cards.
struct SettingsView: View {
    let services: AppServices
    @ObservedObject var tabState: SettingsTabState
    @State private var query = ""
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 232)
                .padding(8)
            content
        }
        .ignoresSafeArea()
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 520)
    }

    // MARK: Sidebar

    var filteredGroups: [[SettingsTab]] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsTab.groups }
        return SettingsTab.groups.map { $0.filter { ($0.rawValue + " " + $0.keywords + " " + $0.subtitle).lowercased().contains(q) } }.filter { !$0.isEmpty }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear.frame(height: 30) // traffic lights sit in this band (52 pt title bar minus card inset)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search settings…", text: $query).textFieldStyle(.plain)
                    .onSubmit { if let first = filteredGroups.first?.first { tabState.select(first) } }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 10) {
                Image("Logo").resizable().scaledToFit().frame(width: 22, height: 22)
                    .padding(5)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Meeting Utility").font(.system(size: 13, weight: .semibold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(filteredGroups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(group) { t in sidebarRow(t) }
                        }
                    }
                    if filteredGroups.isEmpty { Text("No matches").foregroundStyle(.secondary).font(.system(size: 12)).padding(.leading, 8) }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }

    func sidebarRow(_ t: SettingsTab) -> some View {
        let selected = tabState.tab == t
        return Button { tabState.select(t) } label: {
            HStack(spacing: 9) {
                if t == .calendars { DateTile(size: 20) } else { IconTile(symbol: t.icon, color: t.color, size: 20) }
                Text(t.rawValue).font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.rawValue)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: Content

    var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { tabState.goBack() } label: { Image(systemName: "chevron.left").frame(width: 26, height: 22) }
                    .disabled(tabState.back.isEmpty).accessibilityLabel("Back")
                Divider().frame(height: 14)
                Button { tabState.goForward() } label: { Image(systemName: "chevron.right").frame(width: 26, height: 22) }
                    .disabled(tabState.forward.isEmpty).accessibilityLabel("Forward")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .frame(height: 52) // same row as the traffic lights; the scroll view starts below the title band

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    PageHeader(title: tabState.tab.rawValue, subtitle: tabState.tab.subtitle) {
                        if tabState.tab == .calendars { DateTile(size: 60) }
                        else if tabState.tab == .about { Image("Logo").resizable().scaledToFit().frame(width: 60, height: 60) }
                        else { IconTile(symbol: tabState.tab.icon, color: tabState.tab.color, size: 60) }
                    }
                    page
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 26)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
            .id(tabState.tab)
        }
    }

    @ViewBuilder var page: some View {
        switch tabState.tab {
        case .general: GeneralSettings(services: services, settings: services.settings)
        case .calendars: CalendarSettings(services: services, calendar: services.calendar, settings: services.settings)
        case .agenda: AgendaSettings(settings: services.settings)
        case .reminders: ReminderSettings(services: services, settings: services.settings, notifications: services.notifications)
        case .sounds: SoundSettings(settings: services.settings)
        case .automation: AutoJoinSettings(settings: services.settings)
        case .focus: FocusSettings(services: services, settings: services.settings)
        case .transcription: TranscriptionSettings(services: services, settings: services.settings, models: services.models, tabState: tabState)
        case .models: ModelSettings(services: services, models: services.models)
        case .data: DataSettings(services: services)
        case .updates: UpdateSettings(updates: services.updates, settings: services.settings)
        case .diagnostics: DiagnosticsSettings(services: services)
        case .about: AboutSettings(services: services)
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    let services: AppServices
    @ObservedObject var settings: AppSettings
    @State private var loginOn = LoginItem.isEnabled

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Show agenda in", subtitle: "Switching never interrupts a transcription.")
            PresentationModePicker(mode: $settings.presentation).padding(.bottom, 14).frame(maxWidth: .infinity)
            if settings.presentation == .notch {
                RowDivider()
                SettingsRow(title: "Notch display", subtitle: "Without a notch, a small capsule appears below the menu bar.") {
                    Picker("Notch display", selection: $settings.notchDisplayID) {
                        Text("Built-in / automatic").tag(UInt32(0))
                        ForEach(NSScreen.screens, id: \.displayID) { s in Text(s.localizedName).tag(s.displayID) }
                    }.labelsHidden().fixedSize()
                }
                RowDivider()
                SettingsRow(title: "Expand when hovering", subtitle: "Open the agenda by moving the pointer over it.") { Switch(isOn: $settings.notchHoverExpands, label: "Expand when hovering") }
            }
        }
        GroupLabel("Menu bar")
        SettingsCard {
            SettingsRow(title: "Compact status", subtitle: "What is shown without opening the agenda.") {
                Picker("Compact status", selection: $settings.compactStatus) {
                    Text("Meeting").tag(CompactStatusContent.meeting)
                    Text("Quarter").tag(CompactStatusContent.quarter)
                    Text("Meeting + quarter").tag(CompactStatusContent.meetingAndQuarter)
                }.labelsHidden().fixedSize()
            }
            RowDivider()
            SettingsRow(title: "Meeting title length", subtitle: "Shorten titles in a crowded menu bar.") {
                Picker("Meeting title length", selection: $settings.statusTitleLength) {
                    Text("Icon only").tag(StatusTitleLength.iconOnly)
                    Text("Short").tag(StatusTitleLength.short)
                    Text("Medium").tag(StatusTitleLength.medium)
                    Text("Long").tag(StatusTitleLength.long)
                }.labelsHidden().fixedSize()
            }
            RowDivider()
            SettingsRow(title: "Quarter chip", subtitle: "Show quarter progress in the agenda.") { Switch(isOn: $settings.showQuarterInAgenda, label: "Quarter chip") }
            RowDivider()
            SettingsRow(title: "Time format") {
                Picker("Time format", selection: $settings.timeFormat) {
                    ForEach(TimeFormatPreference.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().fixedSize()
            }
        }
        GroupLabel("Startup")
        SettingsCard {
            SettingsRow(title: "Open at login", subtitle: LoginItem.statusText) {
                Switch(isOn: $loginOn, label: "Open at login").onChange(of: loginOn) { _, v in LoginItem.set(v) }
            }
            RowDivider()
            SettingsRow(title: "Show in Dock", subtitle: "See at a glance that Meeting Utility is running. Click the icon for Settings.") {
                Switch(isOn: $settings.showInDock, label: "Show in Dock")
            }
            RowDivider()
            SettingsRow(title: "Setup assistant", subtitle: "Walk through permissions and preferences again.") {
                Button("Open…") { services.windows.openOnboarding() }
            }
        }
        GroupLabel("Keyboard shortcuts")
        SettingsCard {
            shortcutRow("Toggle agenda", .toggleAgenda); RowDivider()
            shortcutRow("Join current or next meeting", .joinMeeting); RowDivider()
            shortcutRow("Open notes", .openNotes); RowDivider()
            shortcutRow("Show or hide Talktrack", .toggleTalktrack); RowDivider()
            shortcutRow("Hide Talktrack (screen sharing)", .hideTalktrack); RowDivider()
            shortcutRow("Open Settings", .openSettings)
        }
        Footnote("No shortcuts are set by default — click Record Shortcut to add one. Unmodified keys only work while the relevant window has focus.")
    }

    func shortcutRow(_ title: String, _ name: KeyboardShortcuts.Name) -> some View {
        SettingsRow(title: title) { KeyboardShortcuts.Recorder("", name: name).accessibilityLabel(title) }
    }
}

// MARK: - Calendars

struct CalendarSettings: View {
    let services: AppServices
    @ObservedObject var calendar: CalendarEngine
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Calendar access", subtitle: statusText + (calendar.freshness.lastSuccess.map { " · refreshed \($0.formatted(date: .omitted, time: .shortened))" } ?? "")) {
                switch calendar.authorization {
                case .notDetermined: Button("Connect…") { Task { await calendar.requestAccess() } }
                case .fullAccess: Button("Refresh Now") { calendar.refresh(reason: "manual") }
                default: Button("Open Privacy Settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
                }
            }
        }
        Footnote("macOS labels this permission “full access”. Meeting Utility only reads events; it never creates, edits or deletes them.")
        if calendar.authorization.canRead {
            CalendarPickerList(calendar: calendar, settings: settings)
            Footnote("Missing a Google or Exchange account? Add it in Calendar › Settings › Accounts or System Settings › Internet Accounts; it then appears here.")
        }
    }

    var statusText: String {
        switch calendar.authorization {
        case .notDetermined: "Not connected"
        case .denied: "Denied"
        case .restricted: "Restricted by policy"
        case .writeOnly: "Write-only (cannot read events)"
        case .fullAccess: "Connected (read only)"
        }
    }
}

/// Calendars grouped by account with a switch per calendar (Settings and onboarding).
struct CalendarPickerList: View {
    @ObservedObject var calendar: CalendarEngine
    @ObservedObject var settings: AppSettings
    var body: some View {
        let groups = Dictionary(grouping: calendar.calendars, by: \.sourceTitle).sorted { $0.key < $1.key }
        if groups.isEmpty { Footnote("No calendars found yet.") }
        ForEach(groups, id: \.key) { source, cals in
            GroupLabel(source)
            SettingsCard {
                let sorted = cals.sorted { $0.title < $1.title }
                ForEach(Array(sorted.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { RowDivider() }
                    HStack(spacing: 0) {
                        Circle().fill(Color(.sRGB, red: c.color.red, green: c.color.green, blue: c.color.blue, opacity: 1))
                            .frame(width: 10, height: 10).padding(.leading, 14)
                        SettingsRow(title: c.title, subtitle: calendar.freshness.missingCalendarIDs.contains(c.id) ? "Unavailable right now" : nil) {
                            Switch(isOn: Binding(get: { settings.selectedCalendarIDs.contains(c.id) }, set: { on in
                                if on { settings.selectedCalendarIDs.insert(c.id) } else { settings.selectedCalendarIDs.remove(c.id) }
                            }), label: c.title)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Agenda

struct AgendaSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var apps: [CalendarApps.App] = []

    static let lookaheadOptions: [(Int, String)] = [(-1, "Any time today"), (5, "5 minutes"), (10, "10 minutes"), (15, "15 minutes"), (30, "30 minutes"),
                                                    (60, "1 hour"), (120, "2 hours"), (240, "4 hours")]
    static let hideOptions: [(Int, String)] = [(-1, "When it ends"), (0, "As soon as it starts"), (5, "5 minutes after"), (10, "10 minutes after"),
                                               (15, "15 minutes after"), (30, "30 minutes after")]

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Display options", subtitle: "Show today's next event in the menu bar this long before it starts. Tomorrow's events never appear early.") {
                Picker("Display options", selection: $settings.menuBarLookahead) {
                    ForEach(Self.lookaheadOptions, id: \.0) { Text($0.1).tag($0.0) }
                }.labelsHidden().fixedSize()
            }
            RowDivider()
            SettingsRow(title: "Hide current event", subtitle: "Hide the current event from the menu bar automatically, or after this much time has passed since it started.") {
                Picker("Hide current event", selection: $settings.hideCurrentAfter) {
                    ForEach(Self.hideOptions, id: \.0) { Text($0.1).tag($0.0) }
                }.labelsHidden().fixedSize()
            }
            RowDivider()
            SettingsRow(title: "Default application", subtitle: "Choose the calendar application used to open events.") {
                Menu {
                    ForEach(apps) { app in
                        Button { settings.calendarAppBundleID = app.id } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: icon(app)) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let app = apps.first(where: { $0.id == settings.calendarAppBundleID }) ?? apps.first {
                            Image(nsImage: icon(app)).resizable().frame(width: 16, height: 16)
                            Text(app.name)
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Default calendar application")
            }
        }
        GroupLabel("Events")
        SettingsCard {
            SettingsRow(title: "Only events with a meeting link", subtitle: "Hide events without a Meet, Zoom or Teams link.") { Switch(isOn: $settings.filters.hideLinkless, label: "Only events with a meeting link") }
            RowDivider()
            SettingsRow(title: "Hide all-day events") { Switch(isOn: $settings.filters.hideAllDay, label: "Hide all-day events") }
            RowDivider()
            SettingsRow(title: "Hide declined events", subtitle: "Declined events never trigger automatic actions.") { Switch(isOn: $settings.filters.hideDeclined, label: "Hide declined events") }
            RowDivider()
            SettingsRow(title: "Hide tentative events") { Switch(isOn: $settings.filters.hideTentative, label: "Hide tentative events") }
        }
        Footnote("Cancelled events are never shown. Hidden events keep their notes. Dismissed events stay in the agenda (dimmed) but leave the menu bar and get no reminders or sounds; use the eye on a row to dismiss or restore it.")
            .task { apps = CalendarApps.installed() }
    }

    func icon(_ app: CalendarApps.App) -> NSImage {
        let i = NSWorkspace.shared.icon(forFile: app.url.path)
        i.size = NSSize(width: 16, height: 16)
        return i
    }
}

// MARK: - Reminders

struct ReminderSettings: View {
    let services: AppServices
    @ObservedObject var settings: AppSettings
    @ObservedObject var notifications: NotificationController

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Remind me before meetings", subtitle: "Native notifications with Join, Open notes and Dismiss.") {
                Switch(isOn: Binding(get: { settings.remindersEnabled }, set: { on in
                    if on {
                        Task {
                            // Authorization is requested only when the user enables reminders (§11.3).
                            if notifications.authorization == .notDetermined { _ = await notifications.requestAuthorization() }
                            settings.remindersEnabled = true
                            if settings.reminderOffsets.isEmpty { settings.reminderOffsets = [.ten] }
                        }
                    } else { settings.remindersEnabled = false }
                }), label: "Remind me before meetings")
            }
            if settings.remindersEnabled {
                RowDivider()
                SettingsRow(title: "When", subtitle: "Choose one or more.") {
                    HStack(spacing: 6) {
                        ForEach(ReminderOffset.allCases, id: \.self) { o in
                            let on = settings.reminderOffsets.contains(o)
                            Button("\(o.rawValue) min") { if on { settings.reminderOffsets.remove(o) } else { settings.reminderOffsets.insert(o) } }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                RowDivider()
                SettingsRow(title: "Notification shows", subtitle: "Lock-screen and preview rules from macOS still apply.") {
                    Picker("Notification shows", selection: $settings.reminderPreview) {
                        Text("Meeting title").tag(ReminderPreview.meetingTitle)
                        Text("“Upcoming meeting”").tag(ReminderPreview.generic)
                    }.labelsHidden().fixedSize()
                }
                if notifications.authorization == .denied {
                    RowDivider()
                    SettingsRow(title: "Notifications are off", subtitle: "Allow notifications for Meeting Utility in System Settings.") {
                        Button("Open Settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
                    }
                }
            }
        }
        Footnote("Reminders are scheduled up to 48 hours ahead; missed ones are never replayed. Other calendar apps may send their own alerts.")
    }
}

// MARK: - Sounds

struct SoundSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Sound before meetings", subtitle: "Plays before each meeting shown in your agenda (declined and dismissed ones are skipped).") {
                Switch(isOn: $settings.meetingSoundEnabled, label: "Sound before meetings")
            }
            RowDivider()
            SettingsRow(title: "When") {
                Picker("When", selection: $settings.meetingSoundLead) {
                    ForEach(ChimePlanner.leadOptions, id: \.self) { m in Text(m == 0 ? "At start" : "\(m) min before").tag(m) }
                }.labelsHidden().fixedSize()
            }
            .disabled(!settings.meetingSoundEnabled)
            RowDivider()
            SettingsRow(title: "Sound") { SoundPicker(selection: $settings.meetingSound, volume: settings.soundVolume) }
                .disabled(!settings.meetingSoundEnabled)
        }
        GroupLabel("Interval chime")
        SettingsCard {
            SettingsRow(title: "Play a chime regularly", subtitle: "Aligned to the clock, e.g. every 30 minutes plays at :00 and :30.") {
                Switch(isOn: $settings.intervalSoundEnabled, label: "Play a chime regularly")
            }
            RowDivider()
            SettingsRow(title: "Every") {
                Picker("Every", selection: $settings.intervalMinutes) {
                    ForEach(ChimePlanner.intervalOptions, id: \.self) { Text("\($0) minutes").tag($0) }
                }.labelsHidden().fixedSize()
            }
            .disabled(!settings.intervalSoundEnabled)
            RowDivider()
            SettingsRow(title: "On") { WeekdayChips(selection: $settings.intervalWindow.weekdays) }
                .disabled(!settings.intervalSoundEnabled)
            RowDivider()
            SettingsRow(title: "Between", subtitle: settings.intervalWindow.weekdays.isEmpty ? "Pick at least one day." : nil) {
                HStack(spacing: 6) {
                    HourPicker(label: "From", hour: $settings.intervalWindow.startHour, range: 0...23)
                    Text("and").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                    HourPicker(label: "To", hour: $settings.intervalWindow.endHour, range: 1...24)
                }
            }
            .disabled(!settings.intervalSoundEnabled)
            RowDivider()
            SettingsRow(title: "Sound") { SoundPicker(selection: $settings.intervalSound, volume: settings.soundVolume) }
                .disabled(!settings.intervalSoundEnabled)
        }
        GroupLabel("Volume")
        SettingsCard {
            SettingsRow(title: "Master volume", subtitle: "Applies to all Meeting Utility sounds, relative to your Mac's volume.") {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.system(size: 11))
                    Slider(value: $settings.soundVolume, in: 0...1).frame(width: 160).controlSize(.small)
                        .accessibilityLabel("Master volume").accessibilityValue("\(Int(settings.soundVolume * 100)) percent")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.system(size: 11))
                    Text("\(Int(settings.soundVolume * 100))%").font(.system(size: 12).monospacedDigit()).frame(width: 38, alignment: .trailing)
                }
            }
        }
        Footnote("Sounds are original tones made for Meeting Utility, plus the standard macOS alert sounds. They play only while the app is running and you're at your Mac (not while it sleeps, the display is off or the screen is locked), never replay later, and are not picked up by transcription.")
    }
}

/// M T W T F S S toggles, ordered from the user's first weekday. Values are Calendar weekdays (1 = Sunday).
struct WeekdayChips: View {
    @Binding var selection: Set<Int>
    var body: some View {
        let cal = Calendar.current
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: 4) {
            ForEach(order, id: \.self) { day in
                let on = selection.contains(day)
                Button(cal.veryShortStandaloneWeekdaySymbols[day - 1]) {
                    if on { selection.remove(day) } else { selection.insert(day) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .frame(width: 24, height: 22)
                .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(cal.standaloneWeekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Whole-hour menu in the user's 12/24-hour format; 24 is "Midnight" at the end of the day.
struct HourPicker: View {
    var label: String
    @Binding var hour: Int
    var range: ClosedRange<Int>
    var body: some View {
        Picker(label, selection: $hour) {
            ForEach(Array(range), id: \.self) { Text(Self.title($0)).tag($0) }
        }
        .labelsHidden().fixedSize()
        .accessibilityLabel(label)
    }

    static func title(_ h: Int) -> String {
        if h == 24 { return "Midnight" }
        let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour().minute())
    }
}

/// Sound menu (grouped) with a preview button.
struct SoundPicker: View {
    @Binding var selection: String
    var volume: Double
    var body: some View {
        HStack(spacing: 6) {
            Picker("Sound", selection: $selection) {
                ForEach(["Meeting Utility", "macOS"], id: \.self) { group in
                    Section(group) {
                        ForEach(SoundLibrary.options.filter { $0.group == group }) { Text($0.name).tag($0.id) }
                    }
                }
            }
            .labelsHidden().fixedSize()
            .onChange(of: selection) { _, id in SoundPlayer.shared.play(id, volume: volume) }
            Button { SoundPlayer.shared.play(selection, volume: volume) } label: { Image(systemName: "play.fill") }
                .help("Preview").accessibilityLabel("Preview sound")
        }
    }
}

// MARK: - Auto join

struct AutoJoinSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        SettingsCard {
            SettingsRow(title: "Auto join meetings", subtitle: "Open the meeting link at the scheduled start.") { Switch(isOn: $settings.autoJoinGlobal, label: "Auto join meetings") }
        }
        Footnote("You still handle the provider's pre-join screen; opening a link doesn't mean you joined. Never runs for declined, cancelled or dismissed events, asks when meetings overlap, and only while your Mac is awake. Per-meeting overrides are in each meeting's right-click menu.")
        GroupLabel("How links open")
        SettingsCard {
            ForEach(Array(MeetingProvider.allCases.enumerated()), id: \.element) { i, p in
                if i > 0 { RowDivider() }
                SettingsRow(title: p.displayName, subtitle: p.nativeAppBundleIDs.isEmpty ? "Opens in your browser." : "Falls back to the browser if the app isn't installed.") {
                    Picker(p.displayName, selection: Binding(get: { settings.openPreference(p) }, set: { settings.openPreferences[p] = $0 })) {
                        Text("Default browser").tag(OpenPreference.defaultBrowser)
                        if !p.nativeAppBundleIDs.isEmpty { Text("\(p.displayName) app").tag(OpenPreference.nativeApp) }
                    }.labelsHidden().fixedSize()
                }
            }
        }
    }
}

// MARK: - Focus

struct FocusSettings: View {
    let services: AppServices
    @ObservedObject var settings: AppSettings
    @State private var shortcuts: [ShortcutListing] = []
    @State private var testResult: String?
    @State private var testing = false

    var ready: Bool { settings.focusShortcutIdentifier != nil && settings.focusShortcutTested }

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Do Not Disturb when I join", subtitle: ready ? "Kept on until the scheduled end; an existing Focus is never changed." : "Set up and test the Shortcut below first.") {
                Switch(isOn: $settings.autoFocusEnabled, label: "Do Not Disturb when I join").disabled(!ready)
            }
        }
        Footnote("If any Focus is already on, it is kept. Otherwise Do Not Disturb turns on until the scheduled end and macOS turns it off by itself. Meeting Utility never turns Focus off.")
        GroupLabel("Setup")
        SettingsCard {
            SettingsRow(title: "1. Create the Shortcut", subtitle: "Build “\(FocusShortcutRunner.suggestedName)” once in Shortcuts.") {
                Button("Guide") { if let url = Bundle.main.url(forResource: "FocusShortcutSetup", withExtension: "md") { NSWorkspace.shared.open(url) } }
                Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
            }
            RowDivider()
            SettingsRow(title: "2. Choose it", subtitle: settings.focusShortcutName ?? "No Shortcut selected") {
                Picker("Shortcut", selection: Binding(get: { settings.focusShortcutIdentifier }, set: { id in
                    settings.focusShortcutIdentifier = id
                    settings.focusShortcutName = shortcuts.first { $0.id == id }?.name
                    settings.focusShortcutTested = false
                })) {
                    Text("None").tag(String?.none)
                    ForEach(shortcuts) { s in Text(s.name).tag(String?.some(s.id)) }
                }.labelsHidden().frame(maxWidth: 220)
                Button { Task { shortcuts = await FocusShortcutRunner.listShortcuts() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload Shortcuts")
            }
            RowDivider()
            SettingsRow(title: "3. Test it", subtitle: testResult ?? "Turns on Do Not Disturb for 1 minute if no Focus is active.") {
                if settings.focusShortcutTested && testResult == nil { StatusPill(text: "Tested", ok: true) }
                Button(testing ? "Testing…" : "Test") {
                    testing = true
                    Task {
                        let r = await services.focusRunner.enableIfNoFocus(until: Date().addingTimeInterval(60), sessionID: UUID())
                        testing = false
                        switch r {
                        case .enabledUntil: testResult = "Worked: Do Not Disturb is on for 1 minute."; settings.focusShortcutTested = true
                        case .preservedExisting: testResult = "Worked: a Focus was already on and was kept."; settings.focusShortcutTested = true
                        case .failed(let c): testResult = "Failed (\(c)). Focus was left unchanged."
                        case .notConfigured: testResult = "Choose a Shortcut first."
                        case .disabled: testResult = nil
                        }
                    }
                }
                .disabled(settings.focusShortcutIdentifier == nil || testing)
            }
        }
        .task { shortcuts = await FocusShortcutRunner.listShortcuts() }
    }
}

// MARK: - Transcription

struct TranscriptionSettings: View {
    let services: AppServices
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelManager
    var tabState: SettingsTabState?
    @State private var devices: [AudioDeviceInfo] = []
    @State private var micResult: String?
    @State private var sysResult: String?
    @State private var testing = false

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Auto transcribe meetings", subtitle: "Start when Meeting Utility opens the meeting link; stop at the scheduled end.") {
                Switch(isOn: Binding(get: { settings.automationMode.autoTranscribe }, set: { settings.automationMode = settings.automationMode.settingTranscribe($0) }), label: "Auto transcribe meetings")
            }
            RowDivider()
            SettingsRow(title: "Auto transcribe + summary", subtitle: "Summarize locally after the transcript is saved.") {
                Switch(isOn: Binding(get: { settings.automationMode.autoSummary }, set: { settings.automationMode = settings.automationMode.settingSummary($0) }), label: "Auto transcribe and summary")
            }
            RowDivider()
            SettingsRow(title: "Allow automatic recording", subtitle: "Required before anything is recorded automatically.") {
                Switch(isOn: $settings.automationOptIn, label: "Allow automatic recording").disabled(settings.automationMode == .off)
            }
        }
        Footnote("Opening the same link from Calendar, email or a browser does not start transcription. Audio is processed on this Mac and never saved; only text is kept.")
        GroupLabel("Readiness")
        SettingsCard {
            readinessRow("Speech model", ok: models.isReady(.speechToText), action: models.isReady(.speechToText) ? nil : "Install…")
            if settings.automationMode.autoSummary {
                RowDivider()
                readinessRow("Summary model", ok: models.isReady(.summary), action: models.isReady(.summary) ? nil : "Install…")
            }
            RowDivider()
            readinessRow("Microphone tested", ok: settings.microphoneTested, action: nil)
            RowDivider()
            readinessRow("System audio tested", ok: settings.systemAudioTested, action: nil)
        }
        GroupLabel("Audio sources")
        SettingsCard {
            SettingsRow(title: "Microphone", subtitle: "Your side of the meeting (“You”).") {
                Picker("Microphone", selection: $settings.microphoneUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices.filter(\.hasInput)) { d in Text(d.name).tag(String?.some(d.uid)) }
                }.labelsHidden().frame(maxWidth: 220)
            }
            RowDivider()
            SettingsRow(title: "Voice processing", subtitle: "Reduces echo when using speakers instead of headphones.") { Switch(isOn: $settings.voiceProcessing, label: "Voice processing") }
            RowDivider()
            SettingsRow(title: "Test microphone", subtitle: micResult ?? "Speak for a few seconds after pressing Test.") {
                Button("Test") { testMic() }.disabled(testing)
            }
            RowDivider()
            SettingsRow(title: "Test system audio", subtitle: sysResult ?? "Plays a sound and listens to this Mac's output. macOS asks for permission the first time.") {
                Button("Test") { testSystem() }.disabled(testing)
            }
        }
        Footnote("“Other participants” is everything your Mac plays (excluding Meeting Utility itself), so other apps' sound during a meeting is included. Labels are sources, not verified speakers.")
            .task { devices = AudioDevices.all() }
    }

    func readinessRow(_ title: String, ok: Bool, action: String?) -> some View {
        SettingsRow(title: title) {
            StatusPill(text: ok ? "Ready" : "Not yet", ok: ok)
            if let action { Button(action) { if let tabState { tabState.select(.models) } else { services.windows.openSettings(tab: .models) } } }
        }
    }

    func testMic() {
        testing = true; micResult = "Listening… speak now"
        Task {
            if MicrophoneSource.authorization == .notDetermined { _ = await MicrophoneSource.requestAccess(); services.windows.refocusAfterSystemPrompt() }
            let r = await SourceTest.run(.microphone, microphoneUID: settings.microphoneUID, excludeOwnPlayback: true)
            testing = false
            if let e = r.error { micResult = e == .microphoneDenied ? "Microphone access is off (System Settings › Privacy & Security › Microphone)." : "Could not start: \(e)"; return }
            settings.microphoneTested = r.heardSignal
            micResult = r.heardSignal ? "Heard you (peak \(Int(r.peakDB)) dB)." : "Silence — check the selected microphone and that it isn't muted."
        }
    }

    func testSystem() {
        testing = true; sysResult = "Playing test sound…"
        Task {
            // Our own playback is included only for this test so the test sound can be heard.
            let r = await SourceTest.run(.system, microphoneUID: nil, seconds: 3, excludeOwnPlayback: false, during: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSSound(named: "Submarine")?.play() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { NSSound(named: "Glass")?.play() }
            })
            testing = false
            services.windows.refocusAfterSystemPrompt() // the audio-capture prompt may have appeared
            if let e = r.error { sysResult = "Could not start system audio capture (\(e)). Allow audio capture in System Settings › Privacy & Security."; return }
            settings.systemAudioTested = r.heardSignal
            // Silence is not proof of permission: say what we know (§13.3).
            sysResult = r.heardSignal ? "Captured the test sound." : "Heard only silence. Check the output volume and the audio-capture permission, then try again."
        }
    }
}

// MARK: - Models

struct ModelSettings: View {
    let services: AppServices
    @ObservedObject var models: ModelManager
    @State private var confirmDelete: ModelCatalogEntry?

    var body: some View {
        ForEach(models.catalog.models) { m in
            SettingsCard {
                SettingsRow(title: m.displayName,
                            subtitle: "\(m.purpose == .speechToText ? "Transcription (English)" : "Summaries") · \(ByteCountFormatter.string(fromByteCount: m.totalBytes, countStyle: .file)) · \(m.licenseSPDX)") {
                    controls(m)
                }
                if case .downloading(let r, let t) = models.states[m.id] ?? .absent {
                    ProgressView(value: Double(r), total: Double(max(t, 1))).padding(.horizontal, 14).padding(.bottom, 4)
                }
                RowDivider()
                VStack(alignment: .leading, spacing: 3) {
                    Text(models.states[m.id]?.label ?? "Not installed").font(.system(size: 12, weight: .medium))
                    Text(m.attribution).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Revision \(m.artifactRevision.prefix(12))").font(.system(size: 10).monospaced()).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        Footnote("Nothing is downloaded until you press Download. Files are verified by size and SHA-256 and run entirely on this Mac. Calendar, notes, Talktrack, reminders and the quarter tracker work without them. Free space: \(ByteCountFormatter.string(fromByteCount: models.freeSpaceBytes, countStyle: .file)) · \(models.modelsDir.path)")
            .alert("Remove this model?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { m in
                Button("Remove", role: .destructive) {
                    if models.delete(m) == .inUse {
                        Task {
                            await services.coordinator.stop(reason: .user)
                            _ = models.delete(m, force: true)
                        }
                    }
                    if m.purpose == .summary { for (occ, s) in services.summaries.states where s == .queued { services.summaries.cancel(occurrenceID: occ) } }
                }
            } message: { m in
                Text(services.coordinator.isCapturing && m.purpose == .speechToText ? "It is in use: transcription will stop first. Notes, transcripts and summaries are kept." : "Notes, transcripts and summaries are kept. Queued jobs that need it are cancelled.")
            }
    }

    @ViewBuilder func controls(_ m: ModelCatalogEntry) -> some View {
        switch models.states[m.id] ?? .absent {
        case .absent, .failed:
            Button("Download") { models.startDownload(m) }.buttonStyle(.borderedProminent).tint(Brand.green)
        case .downloading:
            Button("Pause") { models.pause(m) }
            Button("Cancel") { models.cancelDownload(m) }
        case .paused:
            Button("Resume") { models.startDownload(m) }
            Button("Cancel") { models.cancelDownload(m) }
        case .verifying, .loading:
            ProgressView().controlSize(.small)
        case .ready, .inUse:
            StatusPill(text: "Installed · \(ByteCountFormatter.string(fromByteCount: models.diskUse(m), countStyle: .file))", ok: true)
            Button("Remove…") { confirmDelete = m }
        case .incompatible:
            Button("Remove…") { confirmDelete = m }
        }
    }
}

// MARK: - Data

struct DataSettings: View {
    let services: AppServices
    @State private var confirmErase = false
    @State private var eraseModels = false
    @State private var repairs: [(id: UUID, createdAt: Date)] = []
    @State private var backups: [URL] = []

    var body: some View {
        if let e = services.databaseError {
            SettingsCard {
                SettingsRow(title: "Database problem", subtitle: e.message + " Your data file was left untouched; a temporary database is in use.") {
                    Button("Show Folder") { NSWorkspace.shared.activateFileViewerSelecting([services.appSupport]) }
                }
            }
        }
        SettingsCard {
            SettingsRow(title: "Data folder", subtitle: services.appSupport.path) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([services.appSupport]) }
            }
        }
        Footnote("Stored as ordinary local files in your user Library (not encrypted by the app, not synced). OS backups such as Time Machine may include them.")
        GroupLabel("Notebook links")
        SettingsCard {
            if repairs.isEmpty { SettingsRow(title: "No repairs to undo", subtitle: "Manual “Link to existing notebook” changes appear here.") }
            ForEach(Array(repairs.enumerated()), id: \.element.id) { i, r in
                if i > 0 { RowDivider() }
                SettingsRow(title: "Repair on \(r.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                    Button("Undo") { Task { try? await services.store.undoRepair(r.id); repairs = (try? await services.store.pendingRepairs()) ?? [] } }
                }
            }
        }
        GroupLabel("Backups")
        SettingsCard {
            SettingsRow(title: "App backups", subtitle: "\(backups.count) backup(s). Made before database upgrades; deleted content may remain in them.") {
                Button("Remove") { try? services.database?.removeBackups(); backups = services.database?.listBackups() ?? [] }.disabled(backups.isEmpty)
            }
        }
        GroupLabel("Erase")
        SettingsCard {
            SettingsRow(title: "Also delete downloaded models") { Switch(isOn: $eraseModels, label: "Also delete downloaded models") }
            RowDivider()
            SettingsRow(title: "Erase all data", subtitle: "Notebooks, notes, transcripts, summaries, search data, backups and per-meeting settings.") {
                Button("Erase…", role: .destructive) { confirmErase = true }
            }
        }
        Footnote("Your calendars are not changed. Exports you saved elsewhere and OS backups are not affected.")
            .task {
                repairs = (try? await services.store.pendingRepairs()) ?? []
                backups = services.database?.listBackups() ?? []
            }
            .alert("Erase all Meeting Utility data?", isPresented: $confirmErase) {
                Button("Erase and Quit", role: .destructive) {
                    Task {
                        await services.coordinator.stop(reason: .user)
                        services.notifications.removeAll()
                        try? MeetingStore.eraseAll(directory: services.appSupport)
                        if eraseModels { for m in services.models.catalog.models { _ = services.models.delete(m, force: true) } }
                        services.settings.resetAll()
                        exit(0)
                    }
                }
            } message: { Text("This cannot be undone. The app quits afterwards.") }
    }
}

// MARK: - Updates / diagnostics / about

struct UpdateSettings: View {
    @ObservedObject var updates: UpdateController
    @ObservedObject var settings: AppSettings
    var body: some View {
        SettingsCard {
            if updates.isConfigured {
                SettingsRow(title: "Check for updates automatically") {
                    Switch(isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }), label: "Check for updates automatically")
                }
                RowDivider()
                SettingsRow(title: "Download and install automatically") {
                    Switch(isOn: Binding(get: { updates.automaticallyDownloads }, set: { updates.automaticallyDownloads = $0 }), label: "Download and install automatically")
                }
                RowDivider()
            }
            SettingsRow(title: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))",
                        subtitle: updates.lastStatus) {
                if updates.isConfigured { Button("Check Now") { updates.checkForUpdates() } }
            }
        }
        Footnote("Updates are verified with an EdDSA signature and never restart the app during transcription, unsaved edits or a running summary. Model files are never downloaded as part of an app update.")
    }
}

struct DiagnosticsSettings: View {
    let services: AppServices
    @State private var preview = ""
    @State private var pingResult: String?

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Support report", subtitle: "Versions, redacted setup state, model IDs and error codes. No meeting content.") {
                Button("Preview") { Task { preview = await SupportReport.build(services) } }
                if !preview.isEmpty {
                    Button("Save…") {
                        let p = NSSavePanel(); p.nameFieldStringValue = "MeetingUtility-support.txt"
                        if p.runModal() == .OK, let url = p.url { try? preview.write(to: url, atomically: true, encoding: .utf8) }
                    }
                }
            }
            if !preview.isEmpty {
                PlainTextEditor(text: $preview, fontSize: 11, isEditable: false, accessibilityLabel: "Support report preview")
                    .frame(height: 240).padding(.horizontal, 14).padding(.bottom, 12)
            }
            RowDivider()
            SettingsRow(title: "Inference self-test", subtitle: pingResult ?? "Starts the on-demand helper, runs a tiny MLX operation, then lets it exit.") {
                Button("Run") {
                    pingResult = "Running…"
                    Task {
                        do {
                            let p = try await services.inference.ping(probe: true)
                            pingResult = "OK · protocol v\(p.protocolVersion) · \(p.mlxProbe ?? "no probe") · pid \(p.processID)"
                        } catch { pingResult = "Failed: \(error)" }
                    }
                }
            }
        }
    }
}

struct AboutSettings: View {
    let services: AppServices
    var body: some View {
        SettingsCard {
            SettingsRow(title: "Meeting Utility \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
                        subtitle: "Open source under the MIT License. No accounts, telemetry, analytics, cloud AI or sync.") {
                Button("License") { if let u = Bundle.main.url(forResource: "LICENSE", withExtension: nil) { NSWorkspace.shared.open(u) } }
                Button("Notices") { if let u = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") { NSWorkspace.shared.open(u) } }
            }
        }
        GroupLabel("Model attribution")
        SettingsCard {
            ForEach(Array(services.models.catalog.models.enumerated()), id: \.element.id) { i, m in
                if i > 0 { RowDivider() }
                SettingsRow(title: m.displayName,
                            subtitle: "\(m.attribution) License: \(m.licenseSPDX). Source: huggingface.co/\(m.artifactRepository) (upstream \(m.upstreamRepository)).")
            }
        }
    }
}

enum SupportReport {
    @MainActor static func build(_ s: AppServices) async -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        lines.append("Meeting Utility \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Memory \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB · thermal \(ProcessInfo.processInfo.thermalState.rawValue) · lowPower \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        lines.append("Presentation \(s.settings.presentation.rawValue) · compact \(s.settings.compactStatus.rawValue)")
        lines.append("Calendar auth \(s.calendar.authorization.rawValue) · selected calendars \(s.settings.selectedCalendarIDs.count) · freshness \(s.calendar.freshness.state) · gen \(s.calendar.freshness.generation) · missing \(s.calendar.freshness.missingCalendarIDs.count)")
        lines.append("Notifications auth \(s.notifications.authorization.rawValue) · reminders \(s.settings.remindersEnabled) offsets \(s.settings.reminderOffsets.map(\.rawValue).sorted())")
        lines.append("Auto join global \(s.settings.autoJoinGlobal) · next boundary \(s.scheduler.nextBoundary != nil)")
        lines.append("Focus enabled \(s.settings.autoFocusEnabled) · shortcut configured \(s.settings.focusShortcutIdentifier != nil) · tested \(s.settings.focusShortcutTested) · last \(s.coordinator.lastFocusResult.map { String(describing: $0) } ?? "none")")
        lines.append("Automation \(s.settings.automationMode.rawValue) · opt-in \(s.settings.automationOptIn) · mic tested \(s.settings.microphoneTested) · system tested \(s.settings.systemAudioTested) · mic auth \(MicrophoneSource.authorization.rawValue)")
        for m in s.models.catalog.models { lines.append("Model \(m.id)@\(m.artifactRevision.prefix(12)): \(s.models.states[m.id]?.label ?? "?")") }
        lines.append("Capture active \(s.coordinator.isCapturing) · gaps \(s.coordinator.active?.gapCount ?? 0) · lag \(Int(s.coordinator.active?.lagSeconds ?? 0))s")
        lines.append("Summary jobs \(s.summaries.states.values.map(\.rawValue).sorted())")
        if let e = s.databaseError { lines.append("Database error \(e.code.rawValue)") }
        if let e = s.calendar.lastError { lines.append("Calendar error \(e.code.rawValue)") }
        lines.append("Backups \(s.database?.listBackups().count ?? 0)")
        return lines.map(Redactor.scrub).joined(separator: "\n")
    }
}
