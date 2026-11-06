import AppKit
import MeetingCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var services: AppServices!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance (§B1): hand off to the running copy and quit.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        let devTool = UserDefaults.standard.string(forKey: "RenderSnapshots") != nil || UserDefaults.standard.string(forKey: "SelfTest") != nil
        if let other = others.first, !devTool {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let signpost = Log.signposter.beginInterval("launch")
        services = AppServices()
        services.start()
        services.presentation.install()
        Log.signposter.endInterval("launch", signpost)
        SnapshotRenderer.renderIfRequested(services)
        SelfTest.runIfRequested(services)
        if UserDefaults.standard.string(forKey: "RenderSnapshots") != nil || UserDefaults.standard.string(forKey: "SelfTest") != nil { return }
        if !services.settings.onboardingComplete {
            services.windows.openOnboarding()
        } else if let e = services.databaseError {
            services.coordinator.banner = e.message
            services.windows.openSettings(tab: .data)
        }
    }

    /// Reopening the app always reaches Settings (§5.3).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        services?.windows.openSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quit during capture asks Stop and quit / Cancel (§10.6). Pending note edits are flushed first (§9.2).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services else { return .terminateNow }
        if services.coordinator.isCapturing {
            let alert = NSAlert()
            alert.messageText = "Transcription is running"
            alert.informativeText = "Stop transcription and quit? The transcript captured so far is saved."
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            Task {
                await services.coordinator.stop(reason: .appQuit)
                await EditorRegistry.shared.flushAll()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        guard EditorRegistry.shared.hasUnsavedEdits else { return .terminateNow }
        Task {
            await EditorRegistry.shared.flushAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
