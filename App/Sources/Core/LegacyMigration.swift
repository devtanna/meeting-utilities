import Foundation
import MeetingCore

/// One-time move from the pre-release bundle ID (`dev.local.meetingutility`) to the current one, so test builds keep
/// their notes, transcripts, downloaded models and settings. Runs before anything opens the database. Safe to call on
/// every launch: it only acts when old data exists and nothing exists under the new ID yet.
enum LegacyMigration {
    static let legacyBundleID = "dev.local.meetingutility"
    private static let doneKey = "migratedFromLegacyBundleID"

    static func run() {
        guard let current = Bundle.main.bundleIdentifier, current != legacyBundleID else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        // Files: move the whole Application Support folder (database, models, staging) if the new one doesn't exist.
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent(legacyBundleID, isDirectory: true)
        let new = base.appendingPathComponent(current, isDirectory: true)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            do {
                try fm.moveItem(at: old, to: new)
                Log.app.info("migrated application support from legacy bundle ID")
            } catch {
                Log.app.error("legacy application support migration failed")
            }
        }

        // Preferences: copy keys that aren't set yet (window frames, shortcuts and settings included).
        if let legacy = defaults.persistentDomain(forName: legacyBundleID) {
            let existing = defaults.persistentDomain(forName: current) ?? [:]
            for (key, value) in legacy where existing[key] == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: doneKey)
    }
}
