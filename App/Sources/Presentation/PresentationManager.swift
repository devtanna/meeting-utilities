import AppKit
import Combine
import MeetingCore
import SwiftUI

/// Switches between menu-bar and notch presentation without recreating services (§5.3).
@MainActor
final class PresentationManager {
    private unowned let services: AppServices
    private var statusItem: StatusItemController?
    private var notch: NotchPanelController?
    private var cancellables = Set<AnyCancellable>()

    init(services: AppServices) { self.services = services }

    func install() {
        apply(services.settings.presentation)
        services.settings.$presentation.dropFirst().removeDuplicates().sink { [weak self] mode in
            self?.apply(mode)
        }.store(in: &cancellables)
        for publisher in [services.settings.$statusTitleLength.map { _ in () }.eraseToAnyPublisher(),
                          services.settings.$compactStatus.map { _ in () }.eraseToAnyPublisher(),
                          services.settings.$menuBarLookahead.map { _ in () }.eraseToAnyPublisher(),
                          services.settings.$hideCurrentAfter.map { _ in () }.eraseToAnyPublisher(),
                          services.calendar.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                          services.coordinator.objectWillChange.map { _ in () }.eraseToAnyPublisher()] {
            publisher.debounce(for: .milliseconds(50), scheduler: RunLoop.main).sink { [weak self] in self?.refreshCompact() }.store(in: &cancellables)
        }
    }

    private func apply(_ mode: PresentationMode) {
        switch mode {
        case .menuBar:
            notch?.teardown(); notch = nil
            if statusItem == nil { statusItem = StatusItemController(services: services) }
        case .notch:
            statusItem?.teardown(); statusItem = nil
            if notch == nil { notch = NotchPanelController(services: services) }
        }
        refreshCompact()
    }

    var isAgendaVisible: Bool { statusItem?.isShown ?? notch?.isExpanded ?? false }

    func toggleAgenda() {
        if let statusItem { statusItem.toggle() } else { notch?.toggle() }
    }

    func showAgenda() {
        if let statusItem { if !statusItem.isShown { statusItem.toggle() } } else { notch?.expand() }
    }

    func closeAgenda() {
        statusItem?.close(); notch?.collapse()
    }

    func refreshCompact() {
        let text = compactText()
        let c = services.coordinator
        statusItem?.update(title: text, recordingSince: c.isCapturing ? (c.active?.startedAt ?? Date()) : nil)
        notch?.updateCompact()
    }

    /// Compact status content: Meeting / Quarter / Meeting + quarter (§17.2).
    func compactText() -> String {
        let s = services.settings
        let meeting = CountdownFormatter.statusTitle(item: services.calendar.menuBarItem(now: services.now), now: services.now, length: s.statusTitleLength)
        let q = services.quarter
        switch s.compactStatus {
        case .meeting: return meeting
        case .quarter: return q.shortLabel
        case .meetingAndQuarter:
            let short = "Q\(q.quarter) \(q.dayOfQuarter)/\(q.quarterLength)"
            return meeting.isEmpty ? short : "\(meeting) · \(short)"
        }
    }
}

/// Menu-bar mode: one NSStatusItem + one NSPopover hosting the reusable SwiftUI agenda (§5.2).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
        super.init()
        popover.behavior = .transient
        popover.animates = false // agenda appears instantly
        popover.delegate = self
        let host = NSHostingController(rootView: AgendaRoot(services: services, onClose: { [weak self] in self?.close() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked)
            b.imagePosition = .imageLeading
            b.setAccessibilityLabel("Meeting Utility agenda")
        }
        item.autosaveName = "MeetingUtilityStatusItem"
        update(title: "", recordingSince: nil)
    }

    var isShown: Bool { popover.isShown }

    func teardown() {
        recordingTimer?.invalidate()
        popover.close()
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clicked() { toggle() }

    func toggle() {
        if popover.isShown { close(); return }
        guard let b = item.button else { return }
        let signpost = Log.signposter.beginInterval("agenda.open")
        services.calendar.refreshIfOld()
        NSApp.activate()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Log.signposter.endInterval("agenda.open", signpost)
    }

    func close() { popover.performClose(nil) }

    private var title = ""
    private var recordingSince: Date?
    private var recordingTimer: Timer?

    /// The logo and title keep the system menu-bar rendering at all times (a tinted button reads as dark on the
    /// translucent bar). While transcribing, a small red dot and the elapsed time lead the title.
    func update(title: String, recordingSince: Date?) {
        self.title = title
        self.recordingSince = recordingSince
        if recordingSince != nil, recordingTimer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.render() } }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            recordingTimer = t
        } else if recordingSince == nil {
            recordingTimer?.invalidate(); recordingTimer = nil
        }
        render()
    }

    private func render() {
        guard let b = item.button else { return }
        if b.image == nil {
            let img = (NSImage(named: "LogoTemplate")?.copy() as? NSImage).map { i in i.size = NSSize(width: 16, height: 16); i.isTemplate = true; return i }
            img?.accessibilityDescription = "Meeting Utility"
            b.image = img
        }
        b.contentTintColor = nil
        if let since = recordingSince {
            let elapsed = Self.elapsed(Date().timeIntervalSince(since))
            b.attributedTitle = Self.recordingTitle(elapsed: elapsed, title: title)
            b.toolTip = "Transcribing · \(elapsed)" + (title.isEmpty ? "" : "\n" + title)
            b.setAccessibilityLabel("Meeting Utility, transcribing for \(elapsed)")
        } else {
            // Icon-only fallback for crowded menu bars (§5.2).
            b.title = title.isEmpty ? "" : " " + title
            b.toolTip = title.isEmpty ? "Meeting Utility" : title
            b.setAccessibilityLabel("Meeting Utility agenda")
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// " ● 12:34  Title": only the dot carries a colour; the text has no foreground colour so the status bar
    /// draws it like any other menu-bar title. Monospaced digits keep the width steady as the timer ticks.
    static func recordingTitle(elapsed: String, title: String) -> NSAttributedString {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        let out = NSMutableAttributedString(string: " ")
        out.append(NSAttributedString(string: "●", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: size * 0.7),
            .baselineOffset: size * 0.1,
        ]))
        out.append(NSAttributedString(string: " " + elapsed, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]))
        if !title.isEmpty { out.append(NSAttributedString(string: "  " + title, attributes: [.font: NSFont.menuBarFont(ofSize: 0)])) }
        return out
    }
}
