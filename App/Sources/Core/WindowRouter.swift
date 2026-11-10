import AppKit
import MeetingCore
import MeetingData
import SwiftUI

/// Lazily creates normal windows for sustained work (§5.4). One window per notebook keeps one coordinated
/// editor instance per document (§9.2).
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
    private unowned let services: AppServices
    private var notebookWindows: [UUID: (NSWindow, NotebookViewModel)] = [:]
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var talktrack: TalktrackPanelController?
    let settingsTab = SettingsTabState()

    init(services: AppServices) { self.services = services }

    private func makeWindow<V: View>(_ title: String, _ view: V, size: NSSize, autosave: String, chromeless: Bool = false, tallTitlebar: Bool = false) -> NSWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if chromeless { mask.insert(.fullSizeContentView) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: mask, backing: .buffered, defer: true)
        if chromeless {
            // Content runs under a transparent title bar; only the traffic lights remain (no toolbar blur strip).
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            if tallTitlebar {
                // An empty unified toolbar makes a 52 pt title band, placing the traffic lights inside the
                // floating sidebar card. Content below 52 pt never scrolls under it, so there is no blur strip.
                let tb = NSToolbar(identifier: "chrome-\(autosave)")
                tb.showsBaselineSeparator = false
                w.toolbar = tb
                w.toolbarStyle = .unified
            }
        }
        w.title = title
        w.contentViewController = NSHostingController(rootView: view)
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName(autosave)
        if !w.setFrameUsingName(autosave) { w.center() }
        return w
    }

    private func show(_ w: NSWindow) {
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: Notebook

    func openNotebook(for item: AgendaItem) {
        guard let r = services.calendar.resolvedOccurrence(for: item) else { return }
        openNotebook(occurrenceID: r.occurrence.id, resolved: r)
    }

    func openNotebook(occurrenceID: UUID, resolved: ResolvedOccurrence? = nil, tab: NotebookTab? = nil) {
        Task {
            guard let occ = try? await services.store.occurrence(occurrenceID) else { return }
            let nbID = occ.notebookID
            if let (w, model) = notebookWindows[nbID] {
                await model.open(occurrenceID: occurrenceID, resolved: resolved)   // meeting switch flushes first
                if let tab { model.tab = tab }
                show(w)
                return
            }
            let model = NotebookViewModel(services: services)
            let view = NotebookView(model: model, coordinator: services.coordinator, summaries: services.summaries)
            let w = makeWindow("Notebook", view, size: NSSize(width: 980, height: 700), autosave: "NotebookWindow2", chromeless: true, tallTitlebar: true)
            w.identifier = NSUserInterfaceItemIdentifier(nbID.uuidString)
            notebookWindows[nbID] = (w, model)
            await model.open(occurrenceID: occurrenceID, resolved: resolved)
            if let tab { model.tab = tab }
            w.title = model.notebook?.displayTitle ?? "Notebook"
            show(w)
        }
    }

    func closeNotebook(_ id: UUID) {
        notebookWindows[id]?.0.close()
    }

    // MARK: History (month + search)

    func openHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow("Calendar", HistoryView(services: services), size: NSSize(width: 1040, height: 720), autosave: "HistoryWindow2", chromeless: true, tallTitlebar: true)
        }
        show(historyWindow!)
    }

    // MARK: Settings / onboarding

    func openSettings(tab: SettingsTab? = nil) {
        if let tab { settingsTab.tab = tab }
        if settingsWindow == nil {
            settingsWindow = makeWindow("Settings", SettingsView(services: services, tabState: settingsTab), size: NSSize(width: 860, height: 680), autosave: "SettingsWindow2", chromeless: true, tallTitlebar: true)
        }
        show(settingsWindow!)
    }

    func openOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = makeWindow("Welcome to Meeting Utility", OnboardingView(services: services, onFinish: { [weak self] in
                self?.services.settings.onboardingComplete = true
                self?.onboardingWindow?.close()
                self?.services.presentation.showAgenda()
            }), size: NSSize(width: 680, height: 640), autosave: "OnboardingWindow2", chromeless: true)
        }
        show(onboardingWindow!)
    }

    // MARK: Talktrack

    func openTalktrack(for item: AgendaItem) {
        guard let r = services.calendar.resolvedOccurrence(for: item) else { return }
        openTalktrack(notebookID: r.notebook.id, occurrenceID: r.occurrence.id, title: item.event.title)
    }

    func openTalktrack(notebookID: UUID, occurrenceID: UUID, title: String) {
        if talktrack == nil { talktrack = TalktrackPanelController(services: services) }
        talktrack?.open(notebookID: notebookID, occurrenceID: occurrenceID, title: title)
    }

    func toggleTalktrackForCurrent() {
        if let t = talktrack, t.isVisible { t.hide(); return }
        if let t = talktrack, t.hasDocument { t.show(); return }
        guard let item = services.calendar.focusItem() else { return }
        openTalktrack(for: item)
    }

    /// Quick "Hide Talktrack" for screen sharing (§16.3).
    func hideTalktrack() { talktrack?.hide() }

    /// After a macOS permission dialog, focus returns to the previously active app and our window drops behind it.
    /// Bring the window the user was working in back to the front.
    func refocusAfterSystemPrompt() {
        let candidates = [onboardingWindow, settingsWindow].compactMap { $0 }.filter(\.isVisible)
        guard let w = candidates.first(where: \.isKeyWindow) ?? candidates.first else { return }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        if let entry = notebookWindows.first(where: { $0.value.0 === w }) {
            let model = entry.value.1
            notebookWindows.removeValue(forKey: entry.key)
            Task { await model.close() } // flush on window close (§9.2)
        }
        if w === onboardingWindow {
            services.settings.onboardingComplete = true // dismissable; never shown again automatically
            onboardingWindow = nil
        }
    }

    func windowDidResignKey(_ n: Notification) {
        guard let w = n.object as? NSWindow, let entry = notebookWindows.first(where: { $0.value.0 === w }) else { return }
        let m = entry.value.1
        Task { await m.seriesNotes.flush(); await m.occurrenceNotes.flush(); await m.talktrack.flush() } // focus loss
    }
}
