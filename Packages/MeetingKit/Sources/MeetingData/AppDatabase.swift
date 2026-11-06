import Foundation
import GRDB
import MeetingCore

public enum DatabaseOpenError: Error, Sendable {
    case schemaTooNew(found: Int, supported: Int)
    case migrationFailed(String)
}

/// Owns the SQLite database: WAL, synchronous=FULL, user-only permissions, migrations, backups (§18).
public final class AppDatabase: Sendable {
    public static let schemaVersion = 2
    public static let minimumCompatibleSchema = 1

    public let pool: DatabasePool
    public let directory: URL
    public let databaseURL: URL

    public static let didChange = Notification.Name("MeetingDataDidChange")

    public init(directory: URL) throws {
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        databaseURL = directory.appendingPathComponent("store.sqlite")
        let existed = fm.fileExists(atPath: databaseURL.path)

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.journalMode = .wal
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        pool = try DatabasePool(path: databaseURL.path, configuration: config)
        for suffix in ["", "-wal", "-shm"] {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path + suffix)
        }

        // Refuse to open a schema written by a newer app (§18.4).
        let found = try pool.read { db -> Int in
            guard try db.tableExists("app_meta") else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key = 'min_compatible_schema'").flatMap { $0 } ?? 0
        }
        if found > Self.schemaVersion { throw DatabaseOpenError.schemaTooNew(found: found, supported: Self.schemaVersion) }

        let migrator = Self.migrator()
        let needsMigration = try pool.read { try !migrator.hasCompletedMigrations($0) }
        if existed && needsMigration { try backup(label: "pre-migration") }
        do {
            try migrator.migrate(pool)
        } catch {
            throw DatabaseOpenError.migrationFailed(String(describing: type(of: error)))
        }
    }

    /// In-memory-like temporary database for tests.
    public static func temporary() throws -> AppDatabase {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-test-\(UUID().uuidString)")
        return try AppDatabase(directory: dir)
    }

    public var backupsDirectory: URL { directory.appendingPathComponent("Backups") }

    /// Consistent copy through the SQLite backup API (copying store.sqlite alone is insufficient under WAL).
    @discardableResult
    public func backup(label: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = backupsDirectory.appendingPathComponent("\(label)-\(stamp).sqlite")
        let dest = try DatabaseQueue(path: url.path)
        try pool.backup(to: dest)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public func listBackups() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "sqlite" } ?? []
    }

    public func removeBackups() throws {
        for url in listBackups() { try FileManager.default.removeItem(at: url) }
    }

    func notifyChange() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1-initial-schema") { db in
            try db.execute(sql: Schema.v1)
        }
        m.registerMigration("v2-repairs-and-meta") { db in
            try db.execute(sql: Schema.v2)
        }
        return m
    }
}

enum Schema {
    /// Reference schema from §18.3 (verbatim structure).
    static let v1 = """
    CREATE TABLE notebooks (
        id TEXT PRIMARY KEY,
        display_title TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('series', 'single')),
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
    );
    CREATE TABLE calendar_bindings (
        id TEXT PRIMARY KEY,
        notebook_id TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
        source_scope TEXT NOT NULL,
        calendar_scope TEXT NOT NULL,
        last_seen_at_ms INTEGER,
        reconciliation_state TEXT NOT NULL DEFAULT 'linked'
            CHECK (reconciliation_state IN ('linked', 'missing', 'ambiguous')),
        metadata_json TEXT NOT NULL DEFAULT '{}'
    );
    CREATE TABLE calendar_identity_aliases (
        binding_id TEXT NOT NULL REFERENCES calendar_bindings(id) ON DELETE CASCADE,
        alias_kind TEXT NOT NULL,
        source_scope TEXT NOT NULL,
        calendar_scope TEXT NOT NULL,
        alias_value TEXT NOT NULL,
        PRIMARY KEY (binding_id, alias_kind, source_scope, calendar_scope, alias_value)
    );
    CREATE INDEX identity_alias_lookup
    ON calendar_identity_aliases(alias_kind, source_scope, calendar_scope, alias_value);
    CREATE TABLE occurrences (
        id TEXT PRIMARY KEY,
        notebook_id TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
        binding_id TEXT REFERENCES calendar_bindings(id) ON DELETE SET NULL,
        recurrence_anchor_ms INTEGER,
        start_at_ms INTEGER NOT NULL,
        end_at_ms INTEGER NOT NULL,
        event_timezone_id TEXT,
        title_snapshot TEXT NOT NULL,
        event_state TEXT NOT NULL DEFAULT 'active'
            CHECK (event_state IN ('active', 'cancelled', 'missing')),
        dismissed INTEGER NOT NULL DEFAULT 0 CHECK (dismissed IN (0, 1)),
        updated_at_ms INTEGER NOT NULL,
        UNIQUE (id, notebook_id),
        CHECK (end_at_ms >= start_at_ms)
    );
    CREATE UNIQUE INDEX occurrence_anchor_identity
    ON occurrences(binding_id, recurrence_anchor_ms)
    WHERE binding_id IS NOT NULL AND recurrence_anchor_ms IS NOT NULL;
    CREATE INDEX occurrence_month_lookup ON occurrences(start_at_ms);
    CREATE INDEX occurrence_notebook_history ON occurrences(notebook_id, start_at_ms DESC);
    CREATE TABLE documents (
        id TEXT PRIMARY KEY,
        notebook_id TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
        occurrence_id TEXT,
        kind TEXT NOT NULL CHECK (kind IN ('notes', 'talktrack')),
        body TEXT NOT NULL DEFAULT '',
        revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
        updated_at_ms INTEGER NOT NULL,
        FOREIGN KEY (occurrence_id, notebook_id)
            REFERENCES occurrences(id, notebook_id) ON DELETE CASCADE
    );
    CREATE UNIQUE INDEX series_document_scope
    ON documents(notebook_id, kind) WHERE occurrence_id IS NULL;
    CREATE UNIQUE INDEX occurrence_document_scope
    ON documents(occurrence_id, kind) WHERE occurrence_id IS NOT NULL;
    CREATE TABLE document_revisions (
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        revision INTEGER NOT NULL,
        body TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL,
        PRIMARY KEY (document_id, revision)
    );
    CREATE TABLE meeting_sessions (
        id TEXT PRIMARY KEY,
        occurrence_id TEXT NOT NULL REFERENCES occurrences(id) ON DELETE CASCADE,
        state TEXT NOT NULL,
        automation_mode TEXT NOT NULL
            CHECK (automation_mode IN ('off', 'transcript', 'transcriptAndSummary')),
        actual_start_at_ms INTEGER,
        actual_end_at_ms INTEGER,
        calendar_deadline_ms INTEGER NOT NULL,
        user_extended_deadline_ms INTEGER,
        stop_reason TEXT,
        model_id TEXT,
        model_revision TEXT,
        coverage_json TEXT NOT NULL DEFAULT '{}'
    );
    CREATE UNIQUE INDEX one_active_capture
    ON meeting_sessions((1))
    WHERE state IN ('preflight', 'starting', 'capturing', 'stopping');
    CREATE TABLE transcript_segments (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES meeting_sessions(id) ON DELETE CASCADE,
        source TEXT NOT NULL CHECK (source IN ('microphone', 'system', 'combined')),
        sequence INTEGER NOT NULL,
        revision INTEGER NOT NULL DEFAULT 1,
        kind TEXT NOT NULL CHECK (kind IN ('speech', 'gap')),
        start_offset_ms INTEGER NOT NULL CHECK (start_offset_ms >= 0),
        end_offset_ms INTEGER NOT NULL,
        text TEXT NOT NULL DEFAULT '',
        committed INTEGER NOT NULL DEFAULT 1 CHECK (committed IN (0, 1)),
        CHECK (end_offset_ms >= start_offset_ms),
        UNIQUE (session_id, source, sequence)
    );
    CREATE INDEX transcript_session_time
    ON transcript_segments(session_id, start_offset_ms);
    CREATE TABLE summary_versions (
        id TEXT PRIMARY KEY,
        occurrence_id TEXT NOT NULL REFERENCES occurrences(id) ON DELETE CASCADE,
        source_session_ids_json TEXT NOT NULL,
        transcript_digest TEXT NOT NULL,
        model_id TEXT NOT NULL,
        model_revision TEXT NOT NULL,
        prompt_version TEXT NOT NULL,
        generation_json TEXT NOT NULL,
        result_json TEXT NOT NULL,
        user_edited INTEGER NOT NULL DEFAULT 0 CHECK (user_edited IN (0, 1)),
        created_at_ms INTEGER NOT NULL
    );
    CREATE INDEX summary_occurrence_history
    ON summary_versions(occurrence_id, created_at_ms DESC);
    CREATE TABLE automatic_actions (
        occurrence_id TEXT NOT NULL REFERENCES occurrences(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        state TEXT NOT NULL,
        planned_at_ms INTEGER NOT NULL,
        reserved_at_ms INTEGER,
        finished_at_ms INTEGER,
        result_code TEXT,
        PRIMARY KEY (occurrence_id, kind)
    );
    CREATE TABLE durable_jobs (
        id TEXT PRIMARY KEY,
        occurrence_id TEXT NOT NULL REFERENCES occurrences(id) ON DELETE CASCADE,
        kind TEXT NOT NULL CHECK (kind IN ('summary')),
        state TEXT NOT NULL,
        input_revision TEXT NOT NULL,
        progress_json TEXT NOT NULL DEFAULT '{}',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        updated_at_ms INTEGER NOT NULL
    );
    CREATE TABLE scoped_settings (
        scope_kind TEXT NOT NULL,
        scope_id TEXT NOT NULL,
        setting_key TEXT NOT NULL,
        value_json TEXT NOT NULL,
        revision INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (scope_kind, scope_id, setting_key)
    );
    CREATE VIRTUAL TABLE search_documents USING fts5(
        record_id UNINDEXED,
        notebook_id UNINDEXED,
        occurrence_id UNINDEXED,
        content_kind UNINDEXED,
        title,
        body,
        tokenize = 'unicode61'
    );
    """

    /// Extensions: reversible identity repairs (§7.3) and schema compatibility metadata (§18.4).
    static let v2 = """
    CREATE TABLE identity_repairs (
        id TEXT PRIMARY KEY,
        binding_id TEXT NOT NULL,
        from_notebook_id TEXT NOT NULL,
        to_notebook_id TEXT NOT NULL,
        moved_occurrence_ids_json TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL,
        undone_at_ms INTEGER
    );
    CREATE TABLE app_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    INSERT INTO app_meta(key, value) VALUES ('schema_version', '2'), ('min_compatible_schema', '1');
    """
}

extension Date {
    var ms: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
    init(ms: Int64) { self.init(timeIntervalSince1970: Double(ms) / 1000) }
}
