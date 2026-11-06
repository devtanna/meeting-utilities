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
        statusItem?.update(title: text, capturing: services.coordinator.isCapturing)
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
        update(title: "", capturing: false)
    }

    var isShown: Bool { popover.isShown }

    func teardown() {
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

    func update(title: String, capturing: Bool) {
        guard let b = item.button else { return }
        let img: NSImage?
        if capturing {
            img = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Transcribing")
        } else {
            img = (NSImage(named: "LogoTemplate")?.copy() as? NSImage).map { i in i.size = NSSize(width: 16, height: 16); i.isTemplate = true; return i }
            img?.accessibilityDescription = "Meeting Utility"
        }
        b.image = img
        if capturing { b.contentTintColor = .systemRed } else { b.contentTintColor = nil }
        // Icon-only fallback for crowded menu bars (§5.2).
        b.title = title.isEmpty ? "" : " " + title
        b.toolTip = title.isEmpty ? "Meeting Utility" : title
    }
}
