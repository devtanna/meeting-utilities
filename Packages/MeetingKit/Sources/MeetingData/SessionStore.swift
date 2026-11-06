import CryptoKit
import Foundation
import GRDB
import MeetingCore

extension MeetingStore {
    static func session(_ r: Row) -> MeetingSessionRecord {
        let ext: Int64? = r["user_extended_deadline_ms"]
        let start: Int64? = r["actual_start_at_ms"]
        let end: Int64? = r["actual_end_at_ms"]
        let reason: String? = r["stop_reason"]
        return MeetingSessionRecord(
            id: UUID(uuidString: r["id"])!, occurrenceID: UUID(uuidString: r["occurrence_id"])!,
            state: CaptureState(rawValue: r["state"]) ?? .stopped, automationMode: AutomationMode(rawValue: r["automation_mode"]) ?? .off,
            actualStart: start.map(Date.init(ms:)), actualEnd: end.map(Date.init(ms:)), calendarDeadline: Date(ms: r["calendar_deadline_ms"]),
            userExtendedDeadline: ext.map(Date.init(ms:)), stopReason: reason.flatMap(StopReason.init(rawValue:)),
            modelID: r["model_id"], modelRevision: r["model_revision"], coverageJSON: r["coverage_json"])
    }

    // MARK: - Sessions (§10)

    /// Creates a session in `preflight`. The partial unique index guarantees one active capture (§10.5).
    public func createSession(occurrenceID: UUID, mode: AutomationMode, calendarDeadline: Date, modelID: String?, modelRevision: String?) async throws -> MeetingSessionRecord {
        let id = UUID()
        do {
            try await pool.write { db in
                try db.execute(sql: """
                    INSERT INTO meeting_sessions(id, occurrence_id, state, automation_mode, calendar_deadline_ms, model_id, model_revision)
                    VALUES (?, ?, 'preflight', ?, ?, ?, ?)
                    """, arguments: [id.uuidString, occurrenceID.uuidString, mode.rawValue, calendarDeadline.ms, modelID, modelRevision])
            }
        } catch let e as DatabaseError where e.resultCode == .SQLITE_CONSTRAINT {
            throw StoreError.anotherCaptureActive
        }
        db.notifyChange()
        return MeetingSessionRecord(id: id, occurrenceID: occurrenceID, state: .preflight, automationMode: mode, actualStart: nil, actualEnd: nil,
                                    calendarDeadline: calendarDeadline, userExtendedDeadline: nil, stopReason: nil,
                                    modelID: modelID, modelRevision: modelRevision, coverageJSON: "{}")
    }

    /// Transitions through typed domain rules; arbitrary strings cannot bypass the state machine (§18.3).
    public func transition(sessionID: UUID, to next: CaptureState, at date: Date = Date(), reason: StopReason? = nil) async throws {
        try await pool.write { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT * FROM meeting_sessions WHERE id = ?", arguments: [sessionID.uuidString]) else { throw StoreError.notFound }
            let current = Self.session(r).state
            guard current.canTransition(to: next) else { throw StoreError.invalidTransition("\(current.rawValue)->\(next.rawValue)") }
            var sql = "UPDATE meeting_sessions SET state = ?"
            var args: [any DatabaseValueConvertible] = [next.rawValue]
            if next == .capturing { sql += ", actual_start_at_ms = COALESCE(actual_start_at_ms, ?)"; args.append(date.ms) }
            if [.stopped, .interrupted, .failed].contains(next) { sql += ", actual_end_at_ms = COALESCE(actual_end_at_ms, ?)"; args.append(date.ms) }
            if let reason { sql += ", stop_reason = ?"; args.append(reason.rawValue) }
            sql += " WHERE id = ?"; args.append(sessionID.uuidString)
            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
        db.notifyChange()
    }

    public func updateDeadlines(sessionID: UUID, calendar: Date, userExtended: Date?) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE meeting_sessions SET calendar_deadline_ms = ?, user_extended_deadline_ms = ? WHERE id = ?",
                           arguments: [calendar.ms, userExtended?.ms, sessionID.uuidString])
        }
    }

    public func setCoverage(sessionID: UUID, json: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE meeting_sessions SET coverage_json = ? WHERE id = ?", arguments: [json, sessionID.uuidString])
        }
    }

    public func sessions(occurrenceID: UUID) async throws -> [MeetingSessionRecord] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM meeting_sessions WHERE occurrence_id = ? ORDER BY COALESCE(actual_start_at_ms, calendar_deadline_ms)", arguments: [occurrenceID.uuidString]).map(Self.session)
        }
    }

    public func activeSession() async throws -> MeetingSessionRecord? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM meeting_sessions WHERE state IN ('preflight','starting','capturing','stopping') LIMIT 1").map(Self.session)
        }
    }

    /// Crash recovery: any session still active at launch is marked interrupted at its last committed segment (§10.6).
    public func recoverInterruptedSessions() async throws -> Int {
        let n = try await pool.write { db -> Int in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM meeting_sessions WHERE state IN ('preflight','starting','capturing','stopping')")
            for r in rows {
                let s = Self.session(r)
                let lastOffset: Int64? = try Int64.fetchOne(db, sql: "SELECT MAX(end_offset_ms) FROM transcript_segments WHERE session_id = ?", arguments: [s.id.uuidString])
                let end = s.actualStart.map { Date(ms: $0.ms + (lastOffset ?? 0)) } ?? Date()
                try db.execute(sql: "UPDATE meeting_sessions SET state = 'interrupted', stop_reason = 'crashRecovered', actual_end_at_ms = ? WHERE id = ?",
                               arguments: [end.ms, s.id.uuidString])
            }
            return rows.count
        }
        if n > 0 { db.notifyChange() }
        return n
    }

    // MARK: - Transcript segments (§14.4)

    /// Idempotent: unique (session, source, sequence) means an IPC retry does not append duplicates.
    /// A newer revision replaces an older one; an older partial never replaces a completed segment.
    @discardableResult
    public func commitSegment(_ s: TranscriptSegmentRecord, occurrenceID: UUID, notebookID: UUID) async throws -> Bool {
        let changed = try await pool.write { db -> Bool in
            if let existing = try Row.fetchOne(db, sql: "SELECT id, revision, committed FROM transcript_segments WHERE session_id = ? AND source = ? AND sequence = ?",
                                               arguments: [s.sessionID.uuidString, s.source, s.sequence]) {
                let rev: Int = existing["revision"]
                let committed: Int = existing["committed"]
                if rev >= s.revision || (committed == 1 && !s.committed) { return false }
                try db.execute(sql: "UPDATE transcript_segments SET revision = ?, text = ?, start_offset_ms = ?, end_offset_ms = ?, committed = ?, kind = ? WHERE id = ?",
                               arguments: [s.revision, s.text, s.startOffsetMs, max(s.endOffsetMs, s.startOffsetMs), s.committed ? 1 : 0, s.kind.rawValue, existing["id"] as String])
                try Self.upsertSearch(db, recordID: "seg:\(existing["id"] as String)", notebookID: notebookID, occurrenceID: occurrenceID, kind: "transcript", title: "", body: s.text)
                return true
            }
            try db.execute(sql: """
                INSERT INTO transcript_segments(id, session_id, source, sequence, revision, kind, start_offset_ms, end_offset_ms, text, committed)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [s.id.uuidString, s.sessionID.uuidString, s.source, s.sequence, s.revision, s.kind.rawValue,
                                 max(0, s.startOffsetMs), max(s.endOffsetMs, max(0, s.startOffsetMs)), s.text, s.committed ? 1 : 0])
            if s.kind == .speech && !s.text.isEmpty {
                try Self.upsertSearch(db, recordID: "seg:\(s.id.uuidString)", notebookID: notebookID, occurrenceID: occurrenceID, kind: "transcript", title: "", body: s.text)
            }
            return true
        }
        if changed { db.notifyChange() }
        return changed
    }

    public func segments(sessionID: UUID) async throws -> [TranscriptSegmentRecord] {
        try await pool.read { db in try Self.segments(db, sessionIDs: [sessionID.uuidString]) }
    }

    /// All sessions' segments for an occurrence, ordered by wall time then source (overlaps preserved).
    public func transcript(occurrenceID: UUID) async throws -> [(session: MeetingSessionRecord, segments: [TranscriptSegmentRecord])] {
        try await pool.read { db in
            let sessions = try Row.fetchAll(db, sql: "SELECT * FROM meeting_sessions WHERE occurrence_id = ? ORDER BY COALESCE(actual_start_at_ms, calendar_deadline_ms)",
                                            arguments: [occurrenceID.uuidString]).map(Self.session)
            return try sessions.map { ($0, try Self.segments(db, sessionIDs: [$0.id.uuidString])) }
        }
    }

    static func segments(_ db: Database, sessionIDs: [String]) throws -> [TranscriptSegmentRecord] {
        guard !sessionIDs.isEmpty else { return [] }
        let marks = sessionIDs.map { _ in "?" }.joined(separator: ",")
        return try Row.fetchAll(db, sql: "SELECT * FROM transcript_segments WHERE session_id IN (\(marks)) ORDER BY start_offset_ms, source, sequence",
                                arguments: StatementArguments(sessionIDs)).map { r in
            TranscriptSegmentRecord(id: UUID(uuidString: r["id"])!, sessionID: UUID(uuidString: r["session_id"])!, source: r["source"], sequence: r["sequence"],
                                    revision: r["revision"], kind: SegmentKind(rawValue: r["kind"]) ?? .speech, startOffsetMs: r["start_offset_ms"],
                                    endOffsetMs: r["end_offset_ms"], text: r["text"], committed: (r["committed"] as Int) == 1)
        }
    }

    // MARK: - Summaries (§14.5, §14.7)

    public func insertSummary(_ v: SummaryVersionRecord, notebookID: UUID) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO summary_versions(id, occurrence_id, source_session_ids_json, transcript_digest, model_id, model_revision, prompt_version, generation_json, result_json, user_edited, created_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [v.id.uuidString, v.occurrenceID.uuidString, String(decoding: try JSONEncoder().encode(v.sourceSessionIDs), as: UTF8.self),
                                 v.transcriptDigest, v.modelID, v.modelRevision, v.promptVersion, v.generationJSON, v.result.encoded(), v.userEdited ? 1 : 0, v.createdAt.ms])
            try db.execute(sql: "DELETE FROM search_documents WHERE occurrence_id = ? AND content_kind = 'summary'", arguments: [v.occurrenceID.uuidString])
            try Self.upsertSearch(db, recordID: "sum:\(v.id.uuidString)", notebookID: notebookID, occurrenceID: v.occurrenceID, kind: "summary", title: "", body: v.result.markdown())
        }
        db.notifyChange()
    }

    public func summaries(occurrenceID: UUID) async throws -> [SummaryVersionRecord] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM summary_versions WHERE occurrence_id = ? ORDER BY created_at_ms DESC", arguments: [occurrenceID.uuidString]).map { r in
                SummaryVersionRecord(
                    id: UUID(uuidString: r["id"])!, occurrenceID: UUID(uuidString: r["occurrence_id"])!,
                    sourceSessionIDs: (try? JSONDecoder().decode([UUID].self, from: Data((r["source_session_ids_json"] as String).utf8))) ?? [],
                    transcriptDigest: r["transcript_digest"], modelID: r["model_id"], modelRevision: r["model_revision"], promptVersion: r["prompt_version"],
                    generationJSON: r["generation_json"],
                    result: (try? JSONDecoder().decode(SummaryV1.self, from: Data((r["result_json"] as String).utf8))) ?? SummaryV1(),
                    userEdited: (r["user_edited"] as Int) == 1, createdAt: Date(ms: r["created_at_ms"]))
            }
        }
    }

    public static func transcriptDigest(_ segments: [TranscriptSegmentRecord]) -> String {
        var h = SHA256()
        for s in segments { h.update(data: Data("\(s.id)|\(s.revision)|\(s.text)\n".utf8)) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Durable jobs (§14.7)

    public func createJob(occurrenceID: UUID, inputRevision: String) async throws -> DurableJobRecord {
        let job = DurableJobRecord(id: UUID(), occurrenceID: occurrenceID, state: "queued", inputRevision: inputRevision, progressJSON: "{}", attemptCount: 0, updatedAt: Date())
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO durable_jobs(id, occurrence_id, kind, state, input_revision, progress_json, attempt_count, updated_at_ms) VALUES (?, ?, 'summary', 'queued', ?, '{}', 0, ?)",
                           arguments: [job.id.uuidString, occurrenceID.uuidString, inputRevision, job.updatedAt.ms])
        }
        db.notifyChange()
        return job
    }

    public func updateJob(_ id: UUID, state: String, progressJSON: String? = nil, incrementAttempt: Bool = false) async throws {
        try await pool.write { db in
            var sql = "UPDATE durable_jobs SET state = ?, updated_at_ms = ?"
            var args: [any DatabaseValueConvertible] = [state, Date().ms]
            if let progressJSON { sql += ", progress_json = ?"; args.append(progressJSON) }
            if incrementAttempt { sql += ", attempt_count = attempt_count + 1" }
            sql += " WHERE id = ?"; args.append(id.uuidString)
            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
        db.notifyChange()
    }

    public func jobs(states: [String]) async throws -> [DurableJobRecord] {
        try await pool.read { db in
            let marks = states.map { _ in "?" }.joined(separator: ",")
            return try Row.fetchAll(db, sql: "SELECT * FROM durable_jobs WHERE state IN (\(marks)) ORDER BY updated_at_ms", arguments: StatementArguments(states)).map(Self.job)
        }
    }

    public func jobs(occurrenceID: UUID) async throws -> [DurableJobRecord] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM durable_jobs WHERE occurrence_id = ? ORDER BY updated_at_ms DESC", arguments: [occurrenceID.uuidString]).map(Self.job)
        }
    }

    static func job(_ r: Row) -> DurableJobRecord {
        DurableJobRecord(id: UUID(uuidString: r["id"])!, occurrenceID: UUID(uuidString: r["occurrence_id"])!, state: r["state"], inputRevision: r["input_revision"],
                         progressJSON: r["progress_json"], attemptCount: r["attempt_count"], updatedAt: Date(ms: r["updated_at_ms"]))
    }

    /// Jobs left `running` by a crash become `queued` so they resume from text-only checkpoints.
    public func requeueInterruptedJobs() async throws {
        try await pool.write { db in try db.execute(sql: "UPDATE durable_jobs SET state = 'queued' WHERE state = 'running'") }
    }
}
