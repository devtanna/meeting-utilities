import AppKit
import MeetingCore
import MeetingData
import SwiftUI

/// Root used by both the popover and the notch panel.
struct AgendaRoot: View {
    @ObservedObject var services: AppServices
    var onClose: () -> Void
    var body: some View {
        AgendaView(services: services, calendar: services.calendar, coordinator: services.coordinator, scheduler: services.scheduler,
                   settings: services.settings, onClose: onClose)
    }
}

/// Compact agenda matching the reference: actions on top, Today/Tomorrow sections, Settings at the bottom (§5.1).
struct AgendaView: View {
    let services: AppServices
    @ObservedObject var calendar: CalendarEngine
    @ObservedObject var coordinator: MeetingCoordinator
    @ObservedObject var scheduler: AutomationScheduler
    @ObservedObject var settings: AppSettings
    var onClose: () -> Void
    @State private var selectedID: String?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static let width: CGFloat = 430
    static let rowHeight: CGFloat = 24
    static let fontSize: CGFloat = 13

    var selected: AgendaItem? {
        let all = calendar.sections.flatMap(\.items)
        if let selectedID, let s = all.first(where: { $0.id == selectedID }) { return s }
        return calendar.isToday ? calendar.focusItem(now: services.now) : all.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banners
            actions
            Divider().padding(.vertical, 4)
            dateBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !calendar.authorization.canRead {
                        permissionState
                    } else if settings.selectedCalendarIDs.isEmpty {
                        emptyState("No calendars selected", action: "Choose calendars…") { services.windows.openSettings(tab: .calendars) }
                    } else {
                        ForEach(calendar.sections) { section in
                            sectionView(section)
                        }
                    }
                }
            }
            .frame(maxHeight: maxListHeight)
            Divider().padding(.vertical, 4)
            footer
        }
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .font(.system(size: Self.fontSize))
        .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { joinSelected(); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(characters: ["o"], phases: .down) { press in
            guard press.modifiers.contains(.command), let s = selected else { return .ignored }
            services.windows.openNotebook(for: s); onClose(); return .handled
        }
    }

    var maxListHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(200, min(visible - 260, 620))
    }

    // MARK: Banners: capture indicator, conflicts, errors

    @ViewBuilder var banners: some View {
        if let a = coordinator.active {
            CaptureIndicator(state: a, coordinator: coordinator, services: services)
                .padding(.horizontal, 10).padding(.bottom, 4)
        }
        if let resume = coordinator.resumable {
            bannerRow(icon: "pause.circle", text: "Transcription of “\(resume.title)” was interrupted.", tint: .orange) {
                Button("Resume") { Task { await coordinator.resume() } }
            }
        }
        if let target = coordinator.pendingSwitch, let item = calendar.item(occurrenceID: target) {
            bannerRow(icon: "arrow.triangle.swap", text: "Transcribing another meeting. Switch to “\(item.event.title)”?", tint: .orange) {
                Button("Stop current and start this meeting") { Task { await coordinator.switchToPending() } }
                Button("Keep") { coordinator.pendingSwitch = nil }
            }
        }
        if let f = coordinator.startFailure {
            bannerRow(icon: "exclamationmark.triangle", text: f.reason, tint: .orange) {
                if f.canOfferSingleSource, let item = calendar.item(occurrenceID: f.occurrenceID), let r = calendar.resolvedOccurrence(for: item) {
                    Button("Mic only") { Task { await coordinator.startManual(occurrenceID: f.occurrenceID, notebookID: r.notebook.id, title: item.event.title, calendarEnd: item.event.end, duration: nil, sources: [.microphone]) } }
                    Button("Other participants only") { Task { await coordinator.startManual(occurrenceID: f.occurrenceID, notebookID: r.notebook.id, title: item.event.title, calendarEnd: item.event.end, duration: nil, sources: [.system]) } }
                }
                Button("Settings") { services.windows.openSettings(tab: .transcription) }
                Button("Dismiss") { coordinator.startFailure = nil }
            }
        }
        if !scheduler.conflictChoice.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Several meetings start now. Which one should open?", systemImage: "questionmark.circle").foregroundStyle(.orange)
                ForEach(scheduler.conflictChoice) { item in
                    Button("Join “\(item.event.title)”") { scheduler.choose(item) }.buttonStyle(.link)
                }
                Button("Don't join any") { scheduler.choose(nil) }.buttonStyle(.link)
            }
            .padding(8).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 10).padding(.bottom, 4)
        }
        if case .stale = calendar.freshness.state, calendar.authorization.canRead {
            bannerRow(icon: "exclamationmark.arrow.triangle.2.circlepath", text: "Calendar not refreshed; showing last known agenda. Automatic actions paused.", tint: .yellow) {
                Button("Retry") { calendar.refresh(reason: "manual") }
            }
        }
        if !calendar.freshness.missingCalendarIDs.isEmpty {
            bannerRow(icon: "calendar.badge.exclamationmark", text: "\(calendar.freshness.missingCalendarIDs.count) selected calendar(s) unavailable.", tint: .yellow) {
                Button("Calendars…") { services.windows.openSettings(tab: .calendars) }
            }
        }
        if let msg = coordinator.banner { infoBanner(msg) }
    }

    /// Info message with its dismiss button on the same line; secondary details (copy link, Focus result) go below.
    func infoBanner(_ msg: String) -> some View {
        let focus = coordinator.lastFocusResult.flatMap { $0 == .disabled ? nil : $0 }
        let saved = coordinator.lastSavedOccurrenceID
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(msg, systemImage: "info.circle").fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let saved {
                    Button("View Transcript") { services.windows.openNotebook(occurrenceID: saved, tab: .transcript); dismissBanner(); onClose() }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                Button { dismissBanner() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Dismiss message")
            }
            if coordinator.lastFailedLink != nil || focus != nil {
                HStack(spacing: 8) {
                    if let url = coordinator.lastFailedLink { Button("Copy link") { services.opener.copy(url) }.buttonStyle(.link) }
                    if let focus { Text(focus.userMessage).foregroundStyle(.secondary) }
                }
                .font(.system(size: 12))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10).padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    func dismissBanner() {
        coordinator.banner = nil; coordinator.lastFailedLink = nil; coordinator.lastSavedOccurrenceID = nil
    }

    func bannerRow<Buttons: View>(icon: String, text: String, tint: Color, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: icon).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { buttons() }.buttonStyle(.link).font(.system(size: 12))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10).padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: Top actions (Join, Open in Calendar, Dismiss) + Open notes

    @ViewBuilder var actions: some View {
        let item = selected
        VStack(alignment: .leading, spacing: 0) {
            ActionRow(icon: joinIcon(item), title: joinTitle(item), enabled: item?.primaryLink != nil, shortcut: "↩") { joinSelected() }
                .help(item?.primaryLink == nil ? (item == nil ? "No meeting selected" : AppErrorCode.linkMissing.message) : "Opens the meeting link. You handle the provider's pre-join screen.")
            ActionRow(icon: "note.text", title: "Open Notes, Transcripts & Summaries", enabled: item != nil, shortcut: "⌘O") {
                if let item { services.windows.openNotebook(for: item); onClose() }
            }
            ActionRow(icon: "calendar", title: openInTitle, enabled: item != nil) {
                if let item { services.opener.openInCalendar(item.event); onClose() }
            }
            if let item, item.isDismissed {
                ActionRow(icon: "arrow.uturn.backward.circle", title: "Undo Dismiss", enabled: true) { Task { await calendar.dismiss(item, false) } }
            } else {
                ActionRow(icon: "xmark.circle", title: "Dismiss Event", enabled: item != nil) {
                    if let item { Task { await calendar.dismiss(item, true) } }
                }
                .help(AgendaRow.dismissHelp)
            }
            transcriptionAction(item)
        }
    }

    var openInTitle: String {
        settings.calendarAppBundleID == CalendarApps.apple ? "Open in System Calendar" : "Open in \(CalendarApps.name(settings.calendarAppBundleID))"
    }

    /// Start/Stop transcription. While a session is running (started manually or automatically) the row turns light red
    /// and stops it.
    @ViewBuilder func transcriptionAction(_ item: AgendaItem?) -> some View {
        if let a = coordinator.active, a.capture.isActive {
            ActionRow(icon: "stop.fill", title: "Stop Transcription", enabled: a.capture == .capturing || a.capture == .starting,
                      tint: .red, background: Color.red.opacity(0.14)) {
                Task { await coordinator.stop(reason: .user) }
            }
            .help("Transcribing “\(a.title)”. Stopping saves the transcript.")
        } else {
            ActionRow(icon: "play.fill", title: "Start Transcription", enabled: item.flatMap { calendar.resolvedOccurrence(for: $0) } != nil) {
                guard let item, let r = calendar.resolvedOccurrence(for: item) else { return }
                let ended = item.event.end <= Date()
                Task { await coordinator.startManual(occurrenceID: r.occurrence.id, notebookID: r.notebook.id, title: item.event.title,
                                                     calendarEnd: item.event.end, duration: ended ? 30 * 60 : nil) }
            }
            .help(services.models.isReady(.speechToText) ? "Transcribe this meeting on this Mac. Audio is never saved." : "Needs the speech model (Settings › Models).")
        }
    }

    func joinTitle(_ item: AgendaItem?) -> String {
        guard let item else { return "Join" }
        if let p = item.primaryLink?.provider { return p.joinLabel }
        return "No meeting link"
    }

    func joinIcon(_ item: AgendaItem?) -> String {
        switch item?.primaryLink?.provider {
        case .zoom: "video"
        case .googleMeet: "video.badge.waveform"
        case .teams: "person.3"
        case nil: "video.slash"
        }
    }

    func joinSelected() {
        guard let item = selected, item.primaryLink != nil else { return }
        Task { _ = await coordinator.join(item, source: .manual) }
        onClose()
    }

    // MARK: Date navigation + quarter chip

    var dateBar: some View {
        HStack(spacing: 6) {
            Button { calendar.viewedDay = Calendar.current.date(byAdding: .day, value: -1, to: calendar.viewedDay)! } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous day")
            Button("Today") { calendar.viewedDay = Calendar.current.startOfDay(for: Date()) }
                .disabled(calendar.isToday)
            Button { calendar.viewedDay = Calendar.current.date(byAdding: .day, value: 1, to: calendar.viewedDay)! } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next day")
            Button { services.windows.openHistory(); onClose() } label: { Label("Month", systemImage: "calendar") }
            Spacer()
            if settings.showQuarterInAgenda { QuarterChip(info: services.quarter) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }

    // MARK: Sections and rows

    func sectionTitle(_ day: Date) -> String {
        let cal = Calendar.current
        let df = DateFormatter(); df.setLocalizedDateFormatFromTemplate("MMM d")
        let rel = cal.isDateInToday(day) ? "Today" : cal.isDateInTomorrow(day) ? "Tomorrow" : cal.isDateInYesterday(day) ? "Yesterday" : {
            let w = DateFormatter(); w.setLocalizedDateFormatFromTemplate("EEEE"); return w.string(from: day)
        }()
        return "\(rel), \(df.string(from: day))"
    }

    @ViewBuilder func sectionView(_ section: AgendaSection) -> some View {
        Text(sectionTitle(section.day))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
        if section.items.isEmpty {
            Text("No meetings").foregroundStyle(.tertiary).padding(.horizontal, 12).frame(height: Self.rowHeight)
        }
        ForEach(section.items) { item in
            AgendaRow(item: item, now: services.now, isSelected: selected?.id == item.id, timeFormat: settings.timeFormat,
                      active: coordinator.active?.occurrenceID == calendar.occurrenceID(for: item),
                      toggleDismissed: { Task { await calendar.dismiss(item, !item.isDismissed) } })
                .onTapGesture { selectedID = item.id }
                .onTapGesture(count: 2) { selectedID = item.id; services.windows.openNotebook(for: item); onClose() }
                .contextMenu { rowMenu(item) }
        }
    }

    @ViewBuilder func rowMenu(_ item: AgendaItem) -> some View {
        if let link = item.primaryLink {
            Button(link.provider.joinLabel) { Task { _ = await coordinator.join(item, source: .manual) } }
            Button("Copy Meeting Link") { services.opener.copy(link.url) }
        }
        if !item.alternativeLinks.isEmpty {
            Menu("Other Links") {
                ForEach(item.alternativeLinks) { alt in
                    Button("\(alt.provider.displayName) (\(alt.field == .url ? "URL" : alt.field == .location ? "location" : "notes"))") {
                        Task { _ = await coordinator.join(item, source: .manual, candidate: alt) }
                    }
                }
                Divider()
                ForEach(item.alternativeLinks) { alt in
                    Button("Always use \(alt.provider.displayName) link for this series") { setOverride(item, alt, .series) }
                }
            }
        }
        Button("Open Notes, Transcripts & Summaries") { services.windows.openNotebook(for: item) }
        Button("Open Talktrack") { services.windows.openTalktrack(for: item) }
        Button(openInTitle) { services.opener.openInCalendar(item.event) }
        Divider()
        if let r = calendar.resolvedOccurrence(for: item) {
            Button("Start Transcription for This Meeting") {
                let ended = item.event.end <= Date()
                Task { await coordinator.startManual(occurrenceID: r.occurrence.id, notebookID: r.notebook.id, title: item.event.title, calendarEnd: item.event.end, duration: ended ? 30 * 60 : nil) }
            }
            .disabled(coordinator.isCapturing)
            AutoJoinMenu(services: services, occurrenceID: r.occurrence.id, notebookID: r.notebook.id)
        }
        Divider()
        Button(item.isDismissed ? "Undo Dismiss" : "Dismiss Event") { Task { await calendar.dismiss(item, !item.isDismissed) } }
    }

    func setOverride(_ item: AgendaItem, _ link: MeetingLinkCandidate, _ scope: LinkOverrideScope) {
        guard let r = calendar.resolvedOccurrence(for: item) else { return }
        Task {
            try? await services.store.setSetting(LinkOverride(url: link.url.absoluteString, scope: scope),
                                                 scope: scope == .series ? "notebook" : "occurrence",
                                                 id: scope == .series ? r.notebook.id.uuidString : r.occurrence.id.uuidString, key: "linkOverride")
            calendar.refresh(reason: "override")
        }
    }

    func move(_ delta: Int) {
        let all = calendar.sections.flatMap(\.items)
        guard !all.isEmpty else { return }
        let idx = all.firstIndex { $0.id == selected?.id } ?? -1
        selectedID = all[max(0, min(all.count - 1, idx + delta))].id
    }

    // MARK: Permission / empty states

    @ViewBuilder var permissionState: some View {
        switch calendar.authorization {
        case .notDetermined:
            emptyState("Connect your calendars to see meetings.", action: "Connect Calendars…") { Task { await calendar.requestAccess() } }
        case .denied, .restricted, .writeOnly:
            emptyState("Calendar access is off. Meeting Utility only reads events.", action: "Open Privacy Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
        case .fullAccess: EmptyView()
        }
    }

    func emptyState(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).foregroundStyle(.secondary)
            Button(action, action: perform)
        }
        .padding(12)
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            ActionRow(icon: "magnifyingglass", title: "Calendar and Notes…", enabled: true) { services.windows.openHistory(); onClose() }
            ActionRow(icon: "gearshape", title: "Settings", enabled: true, shortcut: "⌘,") { services.windows.openSettings(); onClose() }
            ActionRow(icon: "power", title: "Quit Meeting Utility", enabled: true, shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
    }
}

struct ActionRow: View {
    var icon: String
    var title: String
    var enabled: Bool
    var shortcut: String? = nil
    var tint: Color? = nil
    var background: Color? = nil
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16).foregroundStyle(enabled ? AnyShapeStyle(tint ?? .primary) : AnyShapeStyle(.tertiary))
                Text(title).foregroundStyle(enabled ? AnyShapeStyle(tint ?? .primary) : AnyShapeStyle(.tertiary))
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary).font(.system(size: 12)) }
            }
            .padding(.horizontal, 12)
            .frame(height: AgendaView.rowHeight)
            .background(hover && enabled ? (background?.opacity(1.6) ?? Color.accentColor.opacity(0.18)) : (background ?? .clear), in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .accessibilityLabel(title)
    }
}

/// One compact row: status symbol (calendar colour + RSVP), time range, one-line title (§5.1).
struct AgendaRow: View {
    var item: AgendaItem
    var now: Date
    var isSelected: Bool
    var timeFormat: TimeFormatPreference
    var active: Bool
    var toggleDismissed: () -> Void = {}
    @State private var hover = false

    static let dismissHelp = "Dismiss: hide this meeting from the menu bar and silence its reminders and sounds, for this occurrence only. It stays in this list, and your calendar is unchanged."
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let e = item.event
        let dim = e.rsvp == .declined || item.isDismissed || e.end < now
        HStack(spacing: 8) {
            StatusSymbol(event: e, now: now, active: active)
            Text(timeRange).monospacedDigit().foregroundStyle(dim ? .secondary : .primary)
            Text(e.title).lineLimit(1).truncationMode(.tail).foregroundStyle(dim ? .secondary : .primary)
                .strikethrough(e.rsvp == .declined, color: .secondary)
            Spacer(minLength: 4)
            if item.primaryLink == nil && !e.isAllDay { Image(systemName: "link.badge.plus").opacity(0).accessibilityHidden(true) }
            dismissToggle
        }
        .padding(.horizontal, 12)
        .frame(height: AgendaView.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(contrast == .increased ? 0.4 : 0.22) : hover ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(e.title + (item.primaryLink.map { " — \($0.provider.displayName)" } ?? " — no meeting link"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Eye toggle: always visible (crossed out) when dismissed, otherwise on hover or selection.
    @ViewBuilder var dismissToggle: some View {
        let show = item.isDismissed || hover || isSelected
        Button(action: toggleDismissed) {
            Image(systemName: item.isDismissed ? "eye.slash" : "eye")
                .font(.system(size: 11))
                .foregroundStyle(item.isDismissed ? .secondary : .tertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(show ? 1 : 0)
        .allowsHitTesting(show)
        .help(item.isDismissed ? "Undo dismiss: show in the menu bar again, with reminders and sounds" : Self.dismissHelp)
        .accessibilityLabel(item.isDismissed ? "Undo dismiss" : "Dismiss")
    }

    var timeRange: String {
        if item.event.isAllDay { return "All day" }
        let f = DateFormatter()
        switch timeFormat {
        case .system: f.timeStyle = .short; f.dateStyle = .none
        case .twelveHour: f.dateFormat = "h:mm a"
        case .twentyFourHour: f.dateFormat = "HH:mm"
        }
        return "\(f.string(from: item.event.start)) - \(f.string(from: item.event.end))"
    }

    var accessibilityText: String {
        let rsvp: String = switch item.event.rsvp {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "invitation pending"
        case .organizer: "organizer"
        case .none: ""
        }
        return "\(timeRange), \(item.event.title), \(rsvp)\(item.primaryLink == nil ? ", no meeting link" : ", \(item.primaryLink!.provider.displayName)")\(item.isDismissed ? ", dismissed" : "")"
    }
}

/// Calendar colour + RSVP symbol. Never claims attendance or completion (§5.2).
struct StatusSymbol: View {
    var event: CalendarOccurrenceSnapshot
    var now: Date
    var active: Bool
    var body: some View {
        let c = Color(.sRGB, red: event.calendarColor.red, green: event.calendarColor.green, blue: event.calendarColor.blue, opacity: 1)
        Image(systemName: symbol)
            .foregroundStyle(event.rsvp == .declined ? .secondary : c)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 16)
            .accessibilityHidden(true)
    }
    var symbol: String {
        if active { return "record.circle" }
        if event.isActive(at: now) && event.rsvp != .declined { return "circle.fill" }
        switch event.rsvp {
        case .accepted, .organizer: return "checkmark.circle"
        case .declined: return "xmark.circle"
        case .tentative: return "questionmark.circle"
        case .pending: return "circle.dashed"
        case .none: return "circle"
        }
    }
}

struct QuarterChip: View {
    var info: QuarterInfo
    @State private var showDetail = false

    func cell(_ text: Text, help: String, first: Bool = false, last: Bool = false) -> some View {
        text
            .padding(.leading, first ? 8 : 6).padding(.trailing, last ? 8 : 6).padding(.vertical, 2)
            .background(first ? Color.accentColor.opacity(0.16) : .clear)
            .help(help)
    }

    var separator: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).padding(.vertical, 3) }
    var body: some View {
        Button { showDetail.toggle() } label: {
            // Segmented cells: current quarter · day of quarter · countdown to the next one.
            HStack(spacing: 0) {
                cell(Text("Q\(info.quarter)").fontWeight(.semibold), help: "Quarter \(info.quarter) of \(String(info.year))", first: true)
                separator
                cell(Text("\(info.dayOfQuarter)") + Text("/\(info.quarterLength)").foregroundColor(.secondary),
                     help: "Day \(info.dayOfQuarter) of \(info.quarterLength)")
                separator
                cell(Text("\(info.daysToNextQuarter)D") + Text(" → Q\(info.nextQuarter)").foregroundColor(.secondary),
                     help: "\(info.daysToNextQuarter) days until Q\(info.nextQuarter)", last: true)
            }
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .fixedSize()   // separators would otherwise stretch to fill the height
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quarter \(info.quarter), day \(info.dayOfQuarter) of \(info.quarterLength), \(info.daysToNextQuarter) days to next quarter")
        .popover(isPresented: $showDetail) {
            let df = DateFormatter()
            VStack(alignment: .leading, spacing: 4) {
                Text("Q\(info.quarter) \(info.year)").font(.headline)
                Text("Day \(info.dayOfQuarter) of \(info.quarterLength)")
                Text("\(info.elapsedCompleteDays) complete days elapsed").foregroundStyle(.secondary)
                Text("Q\(info.nextQuarter) \(info.nextQuarterYear) begins \({ df.dateStyle = .long; return df.string(from: info.nextQuarterStart) }())")
                Text("\(info.daysToNextQuarter) days to next quarter")
            }
            .padding(12)
        }
    }
}

struct CaptureIndicator: View {
    var state: ActiveSessionState
    @ObservedObject var coordinator: MeetingCoordinator
    let services: AppServices
    @State private var showCustom = false
    @State private var customMinutes = 30.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: state.capture == .capturing ? "record.circle.fill" : "hourglass").foregroundStyle(.red)
                Text(statusText).font(.system(size: 12, weight: .semibold))
                Spacer()
                if state.capture == .capturing {
                    Button("Stop") { Task { await coordinator.stop(reason: .user) } }
                    Button("+15 min") { coordinator.extend() }
                }
            }
            HStack(spacing: 10) {
                ForEach(state.sources, id: \.self) { s in
                    HStack(spacing: 3) {
                        Text(s.label).foregroundStyle(.secondary)
                        LevelBar(db: state.levels[s] ?? -120)
                    }
                }
                Spacer()
                Text("until \(state.deadline.effective.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            if state.lagSeconds > 15 { Text("Transcription is \(Int(state.lagSeconds)) s behind").font(.system(size: 11)).foregroundStyle(.orange) }
            if state.gapCount > 0 { Text("\(state.gapCount) gap(s) marked in the transcript").font(.system(size: 11)).foregroundStyle(.orange) }
            if let m = state.message { Text(m).font(.system(size: 11)).foregroundStyle(.secondary) }
            if state.showEndPrompt {
                HStack {
                    Text("Scheduled end in under a minute.").font(.system(size: 11))
                    Button("Keep recording +15 min") { coordinator.extend() }
                    Button("Custom…") { showCustom = true }
                }
                .buttonStyle(.link)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcription session")
        .popover(isPresented: $showCustom) {
            VStack {
                Stepper("Extend by \(Int(customMinutes)) minutes", value: $customMinutes, in: 5...240, step: 5)
                Button("Extend") { coordinator.extend(by: customMinutes * 60); showCustom = false }
            }.padding()
        }
    }

    var statusText: String {
        switch state.capture {
        case .preflight, .starting: "Starting transcription… (audio before this is not captured)"
        case .capturing: "Transcribing · \(state.title)"
        case .stopping: "Finishing transcript…"
        default: state.capture.rawValue
        }
    }
}

struct LevelBar: View {
    var db: Float
    var body: some View {
        let v = CGFloat(max(0, min(1, (db + 60) / 60)))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.2))
            Capsule().fill(Color.green).frame(width: 40 * v)
        }
        .frame(width: 40, height: 5)
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int(db)) decibels")
    }
}

struct AutoJoinMenu: View {
    let services: AppServices
    var occurrenceID: UUID
    var notebookID: UUID
    var body: some View {
        Menu("Auto Join") {
            Button("This occurrence: On") { set("occurrence", occurrenceID, true) }
            Button("This occurrence: Off") { set("occurrence", occurrenceID, false) }
            Button("This occurrence: Use series/global") { set("occurrence", occurrenceID, nil) }
            Divider()
            Button("Whole series: On") { set("notebook", notebookID, true) }
            Button("Whole series: Off") { set("notebook", notebookID, false) }
            Button("Whole series: Reset to global") { set("notebook", notebookID, nil) }
        }
    }
    func set(_ scope: String, _ id: UUID, _ v: Bool?) {
        Task {
            try? await services.store.setSetting(v, scope: scope, id: id.uuidString, key: "autoJoin")
            services.scheduler.replan()
        }
    }
}
