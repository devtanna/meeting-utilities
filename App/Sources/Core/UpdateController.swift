import AppKit
import Foundation
import MeetingCore
import Sparkle

/// Sparkle 2 standard flow (§20.1): signed archives, HTTPS appcast, no system profiling, relaunch deferral.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private let settings: AppSettings
    private var canRelaunch: () -> Bool = { true }
    @Published private(set) var isConfigured = false
    @Published private(set) var lastStatus: String?

    init(settings: AppSettings) { self.settings = settings }

    /// Sparkle is started only when a public EdDSA key and HTTPS feed are configured, so a development
    /// build never shows updater errors for the placeholder feed.
    func start(canRelaunch: @escaping () -> Bool) {
        self.canRelaunch = canRelaunch
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        guard !key.isEmpty, feed.hasPrefix("https://"), !feed.contains(".invalid/") else {
            lastStatus = "Updates are not configured for this build (no release feed yet)."
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        isConfigured = true
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvoking installHandler: @escaping () -> Void) -> Bool {
        let ok = MainActor.assumeIsolated { canRelaunch() }
        guard !ok else { return false }
        // Defer during capture, unsaved edits, or a non-checkpointed job; retry every 60 s.
        Log.updates.info("relaunch deferred")
        nonisolated(unsafe) let handler = installHandler
        Task { @MainActor in
            while !self.canRelaunch() { try? await Task.sleep(for: .seconds(60)) }
            await EditorRegistry.shared.flushAll()
            handler()
        }
        return true
    }

    nonisolated func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String] { [] }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        Task { @MainActor in self.lastStatus = AppErrorCode.updateVerifyFailed.message }
    }
}
