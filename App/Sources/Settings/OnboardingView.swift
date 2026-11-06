import AppKit
import AVFoundation
import Combine
import MeetingAudio
import MeetingCore
import SwiftUI

/// Setup assistant: welcome → permissions (calendar + microphone) → calendars → presentation → optional extras → done.
/// Nothing large is downloaded here; models are installed only from Settings › Models on request.
struct OnboardingView: View {
    let services: AppServices
    var onFinish: () -> Void
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var calendar: CalendarEngine
    @ObservedObject private var notifications: NotificationController
    @State private var step = 0
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var loginOn = LoginItem.isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(services: AppServices, initialStep: Int = 0, onFinish: @escaping () -> Void) {
        self.services = services
        _step = State(initialValue: initialStep)
        self.onFinish = onFinish
        settings = services.settings
        calendar = services.calendar
        notifications = services.notifications
    }

    static let stepCount = 6

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 28) // title bar area (traffic lights)
            ScrollView {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: permissions
                    case 2: calendars
                    case 3: presentation
                    case 4: extras
                    default: done
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                .id(step)
            }
            footer
        }
        .ignoresSafeArea()
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshStatuses() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in if step == 1 { refreshStatuses() } }
    }

    func refreshStatuses() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Task { await notifications.refreshAuthorization() }
        if !calendar.authorization.canRead { calendar.refresh(reason: "onboarding") }
    }

    func go(_ s: Int) {
        if reduceMotion { step = s } else { withAnimation(.easeInOut(duration: 0.25)) { step = s } }
    }

    // MARK: Footer: progress dots + navigation

    var footer: some View {
        HStack {
            if step > 0 && step < Self.stepCount - 1 { Button("Back") { go(step - 1) }.controlSize(.large) }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<Self.stepCount, id: \.self) { i in
                    Capsule().fill(i == step ? Brand.green : Color.primary.opacity(0.15)).frame(width: i == step ? 18 : 7, height: 7)
                }
            }
            .accessibilityElement().accessibilityLabel("Step \(step + 1) of \(Self.stepCount)")
            Spacer()
            primaryButton
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    @ViewBuilder var primaryButton: some View {
        switch step {
        case 0: Button("Get Started") { go(1) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Brand.green).controlSize(.large)
        case 1:
            HStack {
                if permissionBlocked { Button("Skip for Now") { go(2) }.controlSize(.large) }
                Button("Continue") { go(2) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Brand.green).controlSize(.large)
                    .disabled(!requiredGranted)
            }
        case Self.stepCount - 1:
            Button("Open Agenda") { onFinish() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Brand.green).controlSize(.large)
        default:
            Button("Continue") { go(step + 1) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Brand.green).controlSize(.large)
        }
    }

    var requiredGranted: Bool { calendar.authorization.canRead && micStatus == .authorized }
    /// Only offer skipping when macOS won't show a prompt any more (denied/restricted), so nobody gets stuck.
    var permissionBlocked: Bool {
        [.denied, .restricted, .writeOnly].contains(calendar.authorization) || micStatus == .denied || micStatus == .restricted
    }

    // MARK: Steps

    var welcome: some View {
        VStack(spacing: 18) {
            Image("Logo").resizable().scaledToFit().frame(width: 84, height: 84)
                .padding(18)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.black.opacity(0.07)))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.top, 30)
            Text("Welcome to Meeting Utility").font(.system(size: 28, weight: .bold))
            Text("Your meetings, one click away — with notes, a teleprompter and private on-device transcripts.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SettingsCard {
                feature("calendar", .red, "Compact agenda", "Today and tomorrow in the menu bar or around the notch.")
                RowDivider()
                feature("video.fill", .green, "One-click join", "Google Meet, Zoom and Microsoft Teams links.")
                RowDivider()
                feature("note.text", .orange, "Notes per meeting series", "Shared series notes plus dated notes for every occurrence.")
                RowDivider()
                feature("lock.fill", Brand.green, "Private by design", "Everything stays on this Mac. No accounts, no cloud.")
            }
            .padding(.top, 6)
        }
    }

    func feature(_ symbol: String, _ color: Color, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 0) {
            IconTile(symbol: symbol, color: color, size: 28).padding(.leading, 14)
            SettingsRow(title: title, subtitle: subtitle)
        }
    }

    var permissions: some View {
        VStack(spacing: 10) {
            PageHeader(title: "Allow access", subtitle: "Meeting Utility needs these to show your meetings and transcribe your side of a call.") {
                IconTile(symbol: "hand.raised.fill", color: .blue, size: 60)
            }
            .padding(.top, 10)
            SettingsCard {
                permissionRow(icon: AnyView(DateTile(size: 32)), title: "Calendar", required: true,
                              subtitle: "Reads your events to build the agenda. macOS calls this “full access”, but events are never changed.",
                              status: calendarStatus) {
                    switch calendar.authorization {
                    case .notDetermined: Button("Allow") { Task { await calendar.requestAccess() } }.buttonStyle(.borderedProminent).tint(Brand.green)
                    case .fullAccess: EmptyView()
                    default: Button("Open Settings…") { openPrivacy("Privacy_Calendars") }
                    }
                }
                RowDivider()
                permissionRow(icon: AnyView(IconTile(symbol: "mic.fill", color: .orange, size: 32)), title: "Microphone", required: true,
                              subtitle: "Transcribes your voice when you start a transcription. Audio is never saved.",
                              status: micText) {
                    switch micStatus {
                    case .notDetermined:
                        Button("Allow") { Task { _ = await MicrophoneSource.requestAccess(); micStatus = AVCaptureDevice.authorizationStatus(for: .audio); services.windows.refocusAfterSystemPrompt() } }
                            .buttonStyle(.borderedProminent).tint(Brand.green)
                    case .authorized: EmptyView()
                    default: Button("Open Settings…") { openPrivacy("Privacy_Microphone") }
                    }
                }
                RowDivider()
                permissionRow(icon: AnyView(IconTile(symbol: "bell.fill", color: Color(red: 1, green: 0.27, blue: 0.4), size: 32)), title: "Notifications", required: false,
                              subtitle: "Optional reminders 10 minutes before meetings.",
                              status: notificationText) {
                    if notifications.authorization == .notDetermined {
                        Button("Allow") {
                            Task {
                                if await notifications.requestAuthorization() {
                                    settings.remindersEnabled = true
                                    if settings.reminderOffsets.isEmpty { settings.reminderOffsets = [.ten] }
                                }
                            }
                        }
                    }
                }
            }
            Footnote(permissionBlocked
                     ? "A permission was turned off. Use Open Settings… to allow it, then come back here — this page updates automatically."
                     : "Other participants' audio (system sound) is requested later, the first time you test or start a transcription.")
        }
    }

    func permissionRow<B: View>(icon: AnyView, title: String, required: Bool, subtitle: String, status: (String, Bool), @ViewBuilder button: () -> B) -> some View {
        HStack(spacing: 0) {
            icon.padding(.leading, 14)
            SettingsRow(title: required ? title : "\(title) (optional)", subtitle: subtitle) {
                if status.1 { StatusPill(text: status.0, ok: true) } else { Text(status.0).font(.system(size: 12)).foregroundStyle(.secondary) }
                button()
            }
        }
    }

    var calendarStatus: (String, Bool) {
        switch calendar.authorization {
        case .fullAccess: ("Allowed", true)
        case .notDetermined: ("", false)
        case .denied: ("Denied", false)
        case .restricted: ("Restricted", false)
        case .writeOnly: ("Write-only", false)
        }
    }

    var micText: (String, Bool) {
        switch micStatus {
        case .authorized: ("Allowed", true)
        case .denied: ("Denied", false)
        case .restricted: ("Restricted", false)
        default: ("", false)
        }
    }

    var notificationText: (String, Bool) {
        switch notifications.authorization {
        case .authorized, .provisional: ("Allowed", true)
        case .denied: ("Off", false)
        default: ("", false)
        }
    }

    func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    var calendars: some View {
        VStack(spacing: 10) {
            PageHeader(title: "Choose calendars", subtitle: "Pick the calendars whose meetings should appear. You can change this any time.") { DateTile(size: 60) }
                .padding(.top, 10)
            if calendar.authorization.canRead {
                CalendarPickerList(calendar: calendar, settings: settings)
                Footnote("Missing an account? Add it in the Calendar app (Calendar › Settings › Accounts) and it appears here.")
            } else {
                SettingsCard { SettingsRow(title: "Calendar access is off", subtitle: "Go back to allow calendar access, or set it up later in Settings › Calendars.") }
            }
        }
    }

    var presentation: some View {
        VStack(spacing: 14) {
            PageHeader(title: "Where should it live?", subtitle: "Show your agenda in the menu bar or around the camera notch.") {
                IconTile(symbol: "menubar.rectangle", color: .blue, size: 60)
            }
            .padding(.top, 10)
            SettingsCard {
                PresentationModePicker(mode: $settings.presentation).padding(.vertical, 18).frame(maxWidth: .infinity)
            }
            Footnote("On Macs without a notch, notch mode shows a small capsule at the top centre of the screen.")
        }
    }

    var extras: some View {
        VStack(spacing: 10) {
            PageHeader(title: "A few extras", subtitle: "All optional — turn them on now or later in Settings.") {
                IconTile(symbol: "sparkles", color: .purple, size: 60)
            }
            .padding(.top, 10)
            SettingsCard {
                SettingsRow(title: "Auto join meetings", subtitle: "Open the meeting link at the scheduled start. You still press the provider's Join button.") {
                    Switch(isOn: $settings.autoJoinGlobal, label: "Auto join meetings")
                }
                RowDivider()
                SettingsRow(title: "Open at login", subtitle: "Start Meeting Utility when you log in.") {
                    Switch(isOn: $loginOn, label: "Open at login").onChange(of: loginOn) { _, v in LoginItem.set(v) }
                }
                RowDivider()
                SettingsRow(title: "Do Not Disturb during meetings", subtitle: "Needs a one-time Shortcut. Set it up in Settings › Focus.") {
                    Button("Set Up…") { services.windows.openSettings(tab: .focus) }
                }
                RowDivider()
                SettingsRow(title: "Local transcription & summaries", subtitle: "Optional on-device models (about 2.5 GB + 2.3 GB). Nothing downloads until you choose it in Settings › Models.") {
                    Button("View Models…") { services.windows.openSettings(tab: .models) }
                }
            }
        }
    }

    var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Brand.green).padding(.top, 40)
            Text("You're all set").font(.system(size: 28, weight: .bold))
            Text("Meeting Utility now lives in your \(settings.presentation == .menuBar ? "menu bar" : "notch area").")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Open the agenda", subtitle: "Click the logo in the menu bar.")
                RowDivider()
                SettingsRow(title: "Join a meeting", subtitle: "Select it in the agenda and press Return.")
                RowDivider()
                SettingsRow(title: "Keyboard shortcuts", subtitle: "None are set by default. Add your own in Settings › General.") {
                    Button("Set Up…") { services.windows.openSettings(tab: .general) }
                }
            }
            .padding(.top, 8)
        }
    }
}
