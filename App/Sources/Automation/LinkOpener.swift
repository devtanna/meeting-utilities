import AppKit
import Foundation
import MeetingCore

/// Opens validated provider URLs through NSWorkspace (§8.3). Success means macOS accepted the request; it never
/// confirms admission to the call.
@MainActor
final class LinkOpener {
    private let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    enum OpenOutcome: Equatable { case opened, failed, appMissingUsedBrowser }

    func open(_ candidate: MeetingLinkCandidate) async -> OpenOutcome {
        let ws = NSWorkspace.shared
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if settings.openPreference(candidate.provider) == .nativeApp {
            if let appURL = candidate.provider.nativeAppBundleIDs.lazy.compactMap({ ws.urlForApplication(withBundleIdentifier: $0) }).first {
                do {
                    _ = try await ws.open([candidate.url], withApplicationAt: appURL, configuration: config)
                    Log.opening.info("open native provider=\(candidate.provider.rawValue, privacy: .public)")
                    return .opened
                } catch {
                    Log.opening.error("native open failed provider=\(candidate.provider.rawValue, privacy: .public)")
                }
            }
            // Requested app missing: fall back to the browser; remembered only if the user asks.
            return await openInBrowser(candidate.url, config) ? .appMissingUsedBrowser : .failed
        }
        return await openInBrowser(candidate.url, config) ? .opened : .failed
    }

    private func openInBrowser(_ url: URL, _ config: NSWorkspace.OpenConfiguration) async -> Bool {
        let ws = NSWorkspace.shared
        guard let browser = ws.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return ws.open(url) }
        do {
            _ = try await ws.open([url], withApplicationAt: browser, configuration: config)
            return true
        } catch {
            return false
        }
    }

    func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// `ical://ekevent/...` is a compatibility behavior (MeetingBar), not an Apple API; fall back to Calendar at the date (§8.3).
    func openInCalendar(_ event: CalendarOccurrenceSnapshot) {
        let ws = NSWorkspace.shared
        // A third-party calendar app chosen in Settings › Agenda is simply launched (no stable per-event deep links).
        let chosen = settings.calendarAppBundleID
        if chosen != CalendarApps.apple, let url = ws.urlForApplication(withBundleIdentifier: chosen) {
            ws.openApplication(at: url, configuration: .init())
            return
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let enc = event.calendarItemIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? event.calendarItemIdentifier
        let deep = URL(string: "ical://ekevent/\(df.string(from: event.start))/\(enc)?method=show&options=more")
        if let deep, ws.urlForApplication(toOpen: deep) != nil, ws.open(deep) { return }
        let ts = Int(event.start.timeIntervalSinceReferenceDate)
        if let dateURL = URL(string: "ical://\(ts)"), ws.open(dateURL) { return }
        if let cal = ws.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            ws.openApplication(at: cal, configuration: .init())
        }
    }
}
