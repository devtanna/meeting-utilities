import AppKit
import SwiftUI

/// `-RenderSnapshots <dir>`: renders key views offscreen to PNGs for visual acceptance (R03) without screen-capture
/// permission. Use with `-UseFakeCalendar YES`; never uses real calendar data in captures.
@MainActor
enum SnapshotRenderer {
    static func renderIfRequested(_ services: AppServices) {
        guard let dir = UserDefaults.standard.string(forKey: "RenderSnapshots") else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            let out = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                render(AgendaRoot(services: services, onClose: {}), size: NSSize(width: 430, height: 700), appearance: appearance, to: out.appendingPathComponent("agenda-\(suffix).png"))
            }
            for tab in [SettingsTab.general, .calendars, .agenda, .sounds, .transcription, .models] {
                let st = SettingsTabState(); st.tab = tab
                render(SettingsView(services: services, tabState: st), size: NSSize(width: 860, height: 680), appearance: .aqua, to: out.appendingPathComponent("settings-\(tab.rawValue).png"))
            }
            let dark = SettingsTabState(); dark.tab = .general
            render(SettingsView(services: services, tabState: dark), size: NSSize(width: 860, height: 680), appearance: .darkAqua, to: out.appendingPathComponent("settings-General-dark.png"))
            for step in 0..<6 {
                render(OnboardingView(services: services, initialStep: step, onFinish: {}), size: NSSize(width: 680, height: 640), appearance: .aqua, to: out.appendingPathComponent("onboarding-\(step).png"))
            }
            render(HistoryView(services: services), size: NSSize(width: 1040, height: 720), appearance: .aqua, to: out.appendingPathComponent("history.png"))
            if let item = services.calendar.agendaItems.first(where: { $0.event.title.contains("Customer") }) ?? services.calendar.agendaItems.first,
               let r = services.calendar.resolvedOccurrence(for: item) {
                let nb = NotebookViewModel(services: services)
                await nb.open(occurrenceID: r.occurrence.id, resolved: r)
                nb.occurrenceNotes.text = "## Agenda\n- Wins from last week\n- Customer feedback themes\n- Priorities for next week\n\nSam to send the recap."
                render(NotebookView(model: nb, coordinator: services.coordinator, summaries: services.summaries), size: NSSize(width: 980, height: 700), appearance: .aqua, to: out.appendingPathComponent("notebook.png"))
                let tt = TalktrackModel(services: services)
                tt.title = item.event.title
                tt.editor.text = "Good morning everyone.\n\nToday I want to walk through three things: what customers told us this month, what we changed because of it, and what we'll try next.\n\nFirst, the most common request was a simpler setup."
                render(TalktrackView(model: tt, settings: services.settings, onPin: { _ in }, onClose: {}), size: NSSize(width: 600, height: 380), appearance: .darkAqua, to: out.appendingPathComponent("talktrack.png"))
                tt.editor.text = ""
            }
            if UserDefaults.standard.bool(forKey: "QuitAfterSnapshots") { exit(0) }
        }
    }

    static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
