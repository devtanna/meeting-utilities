import AppKit
import MeetingCore
import MeetingData
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
            await renderTranscript(services, to: out)
            if UserDefaults.standard.bool(forKey: "QuitAfterSnapshots") { exit(0) }
        }
    }

    /// A saved sample transcript (synthetic sandbox only), the agenda banner that links to it, and its notebook tab.
    static func renderTranscript(_ services: AppServices, to out: URL) async {
        guard let item = services.calendar.agendaItems.dropFirst().first, let r = services.calendar.resolvedOccurrence(for: item) else { return }
        let store: MeetingStore = services.store
        if ((try? await store.transcript(occurrenceID: r.occurrence.id)) ?? []).isEmpty,
           let session = try? await store.createSession(occurrenceID: r.occurrence.id, mode: .transcript, calendarDeadline: item.event.end, modelID: nil, modelRevision: nil) {
            try? await store.transition(sessionID: session.id, to: .starting)
            try? await store.transition(sessionID: session.id, to: .capturing)
            let lines = ["Okay, let's get started. Thanks everyone for joining.", "Quick update from my side: the release went out yesterday and the rollout looks healthy so far.",
                         "Great. Any issues from support?", "Two tickets about the settings page, both already fixed in the next build.",
                         "Perfect. Then let's spend the rest of the time on planning for next week.", "Sounds good."]
            for (i, text) in lines.enumerated() {
                let seg = TranscriptSegmentRecord(sessionID: session.id, source: i % 2 == 0 ? "microphone" : "system", sequence: i, kind: .speech,
                                                  startOffsetMs: i * 6_500, endOffsetMs: i * 6_500 + 6_000, text: text)
                _ = try? await store.commitSegment(seg, occurrenceID: r.occurrence.id, notebookID: r.notebook.id)
            }
            try? await store.transition(sessionID: session.id, to: .stopping, reason: .user)
            try? await store.transition(sessionID: session.id, to: .stopped, reason: .user)
        }
        services.coordinator.banner = "Transcription saved"
        services.coordinator.lastSavedOccurrenceID = r.occurrence.id
        render(AgendaRoot(services: services, onClose: {}), size: NSSize(width: 430, height: 700), appearance: .aqua, to: out.appendingPathComponent("agenda-saved.png"))
        services.coordinator.banner = nil
        let nb = NotebookViewModel(services: services)
        await nb.open(occurrenceID: r.occurrence.id, resolved: r)
        nb.tab = .transcript
        render(NotebookView(model: nb, coordinator: services.coordinator, summaries: services.summaries), size: NSSize(width: 980, height: 700), appearance: .aqua, to: out.appendingPathComponent("notebook-transcript.png"))
        render(NotebookView(model: nb, coordinator: services.coordinator, summaries: services.summaries), size: NSSize(width: 980, height: 700), appearance: .darkAqua, to: out.appendingPathComponent("notebook-transcript-dark.png"))
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
