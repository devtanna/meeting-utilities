import Foundation
import GRDB
import MeetingCore

/// Typed repositories over SQLite. One writer (GRDB serializes writes); reads use the pool (§4.3, §18.2).
public final class MeetingStore: Sendable {
    public let db: AppDatabase
    var pool: DatabasePool { db.pool }

    public static let recoveryRevisionLimit = 20
    public static let recoverySnapshotInterval: TimeInterval = 60

    public init(database: AppDatabase) { db = database }

    // MARK: - Row mapping

    static func notebook(_ r: Row) -> NotebookRecord {
        NotebookRecord(id: UUID(uuidString: r["id"])!, displayTitle: r["display_title"], kind: NotebookKind(rawValue: r["kind"]) ?? .single,
                       createdAt: Date(ms: r["created_at_ms"]), updatedAt: Date(ms: r["updated_at_ms"]))
    }

    static func occurrence(_ r: Row) -> OccurrenceRecord {
        let bindingID: String? = r["binding_id"]
        let anchor: Int64? = r["recurrence_anchor_ms"]
        return OccurrenceRecord(
            id: UUID(uuidString: r["id"])!, notebookID: UUID(uuidString: r["notebook_id"])!,
            bindingID: bindingID.flatMap(UUID.init(uuidString:)), recurrenceAnchor: anchor.map(Date.init(ms:)),
            start: Date(ms: r["start_at_ms"]), end: Date(ms: r["end_at_ms"]), timeZoneID: r["event_timezone_id"],
            titleSnapshot: r["title_snapshot"], eventState: EventState(rawValue: r["event_state"]) ?? .active,
            dismissed: (r["dismissed"] as Int) == 1)
    }

    // MARK: - Identity resolution (§7.2)

    /// Maps an EventKit snapshot to stable app UUIDs, creating notebook/binding/occurrence rows as needed.
    /// Never creates documents (lazy creation, §9.1).
    public func resolve(_ e: CalendarOccurrenceSnapshot, now: Date = Date()) async throws -> ResolvedOccurrence {
        let result = try await pool.write { db in try Self.resolve(db, e, now: now, presentLocalIDs: []) }
        return result
    }

    public func resolveAll(_ events: [CalendarOccurrenceSnapshot], now: Date = Date()) async throws -> [String: ResolvedOccurrence] {
        let out = try await pool.write { db -> [String: ResolvedOccurrence] in
            var out: [String: ResolvedOccurrence] = [:]
            // Local IDs present in this fetch distinguish duplicate calendar copies from identifier churn.
            let present = Set(events.map { "\($0.sourceID)|\($0.calendarID)|\($0.calendarItemIdentifier)" })
            for e in events { out[e.id] = try Self.resolve(db, e, now: now, presentLocalIDs: present) }
            return out
        }
        db.notifyChange()
        return out
    }

    static func bindings(_ db: Database, kind: String, source: String, calendar: String, value: String) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT a.binding_id FROM calendar_identity_aliases a
            WHERE a.alias_kind = ? AND a.source_scope = ? AND a.calendar_scope = ? AND a.alias_value = ?
            """, arguments: [kind, source, calendar, value])
    }

    static func addAlias(_ db: Database, binding: String, kind: String, e: CalendarOccurrenceSnapshot, value: String) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO calendar_identity_aliases(binding_id, alias_kind, source_scope, calendar_scope, alias_value)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [binding, kind, e.sourceID, e.calendarID, value])
    }

    static func resolve(_ db: Database, _ e: CalendarOccurrenceSnapshot, now: Date, presentLocalIDs: Set<String>) throws -> ResolvedOccurrence {
        let nowMs = now.ms
        var bindingID: String?
        var state: ReconciliationState = .linked
        var suggestions: [NotebookRecord] = []

        // 1. Existing binding by scoped local alias.
        let local = try bindings(db, kind: "local", source: e.sourceID, calendar: e.calendarID, value: e.calendarItemIdentifier)
        if local.count == 1 {
            bindingID = local[0]
        } else if local.count > 1 {
            bindingID = local.sorted()[0]
        }
        // 3. Scoped external identifier reconciles local-ID churn only when unique.
        if bindingID == nil, let ext = e.externalIdentifier, !ext.isEmpty {
            var byExt = try bindings(db, kind: "external", source: e.sourceID, calendar: e.calendarID, value: ext)
            // A binding whose own local alias is still present in this fetch is a duplicate copy, not churn.
            let stillPresent = try byExt.filter { b in
                try String.fetchAll(db, sql: "SELECT alias_value FROM calendar_identity_aliases WHERE binding_id = ? AND alias_kind = 'local'", arguments: [b])
                    .contains { presentLocalIDs.contains("\(e.sourceID)|\(e.calendarID)|\($0)") }
            }
            if !stillPresent.isEmpty && stillPresent.count == byExt.count && byExt.count == 1 {
                byExt = [] // separate notebook for a convincing duplicate copy; never merged on title/time/link
            }
            if byExt.count == 1 {
                bindingID = byExt[0]
                try addAlias(db, binding: byExt[0], kind: "local", e: e, value: e.calendarItemIdentifier)
                Log.identity.info("identity: reconciled local-id churn via external id")
            } else if byExt.count > 1 {
                state = .ambiguous
                suggestions = try NotebookRecord.fetchForBindings(db, byExt)
            }
        }

        // New binding + notebook when nothing matched (or provisional when ambiguous).
        if bindingID == nil {
            let notebookID = UUID().uuidString
            try db.execute(sql: "INSERT INTO notebooks(id, display_title, kind, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?)",
                           arguments: [notebookID, e.title, e.isRecurring ? "series" : "single", nowMs, nowMs])
            let b = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO calendar_bindings(id, notebook_id, source_scope, calendar_scope, last_seen_at_ms, reconciliation_state)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [b, notebookID, e.sourceID, e.calendarID, nowMs, state.rawValue])
            try addAlias(db, binding: b, kind: "local", e: e, value: e.calendarItemIdentifier)
            if let ext = e.externalIdentifier, !ext.isEmpty { try addAlias(db, binding: b, kind: "external", e: e, value: ext) }
            bindingID = b
        } else {
            try db.execute(sql: "UPDATE calendar_bindings SET last_seen_at_ms = ? WHERE id = ?", arguments: [nowMs, bindingID!])
            let st: String? = try String.fetchOne(db, sql: "SELECT reconciliation_state FROM calendar_bindings WHERE id = ?", arguments: [bindingID!])
            state = ReconciliationState(rawValue: st ?? "linked") ?? .linked
            if let ext = e.externalIdentifier, !ext.isEmpty { try addAlias(db, binding: bindingID!, kind: "external", e: e, value: ext) }
        }
        let binding = bindingID!
        guard let nbRow = try Row.fetchOne(db, sql: """
            SELECT n.* FROM notebooks n JOIN calendar_bindings b ON b.notebook_id = n.id WHERE b.id = ?
            """, arguments: [binding]) else { throw StoreError.notFound }
        var notebook = notebook(nbRow)

        // Series title change updates the display name; historical occurrence titles stay (§7.3).
        if notebook.displayTitle != e.title && e.end > now {
            try db.execute(sql: "UPDATE notebooks SET display_title = ?, updated_at_ms = ? WHERE id = ?", arguments: [e.title, nowMs, notebook.id.uuidString])
            notebook.displayTitle = e.title
        }

        // 2./4. Occurrence by recurrence anchor (recurring) or the binding's single occurrence (standalone).
        let anchorMs: Int64? = e.isRecurring ? e.recurrenceAnchor.ms : nil
        let occRow: Row?
        if let anchorMs {
            occRow = try Row.fetchOne(db, sql: "SELECT * FROM occurrences WHERE binding_id = ? AND recurrence_anchor_ms = ?", arguments: [binding, anchorMs])
        } else {
            occRow = try Row.fetchOne(db, sql: "SELECT * FROM occurrences WHERE binding_id = ? AND recurrence_anchor_ms IS NULL ORDER BY start_at_ms DESC LIMIT 1", arguments: [binding])
        }
        let eventState = e.isCancelled ? "cancelled" : "active"
        var occ: OccurrenceRecord
        if let occRow {
            occ = occurrence(occRow)
            // Reschedule updates times in place; never a second dated entry (§7.3).
            let keepTitle = occ.end <= now ? occ.titleSnapshot : e.title
            try db.execute(sql: """
                UPDATE occurrences SET start_at_ms = ?, end_at_ms = ?, event_timezone_id = ?, title_snapshot = ?, event_state = ?, updated_at_ms = ?
                WHERE id = ?
                """, arguments: [e.start.ms, max(e.end.ms, e.start.ms), e.timeZoneID, keepTitle, eventState, nowMs, occ.id.uuidString])
            occ.start = e.start; occ.end = max(e.end, e.start); occ.titleSnapshot = keepTitle
            occ.eventState = EventState(rawValue: eventState)!; occ.timeZoneID = e.timeZoneID
        } else {
            let id = UUID()
            try db.execute(sql: """
                INSERT INTO occurrences(id, notebook_id, binding_id, recurrence_anchor_ms, start_at_ms, end_at_ms, event_timezone_id, title_snapshot, event_state, dismissed, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                """, arguments: [id.uuidString, notebook.id.uuidString, binding, anchorMs, e.start.ms, max(e.end.ms, e.start.ms), e.timeZoneID, e.title, eventState, nowMs])
            occ = OccurrenceRecord(id: id, notebookID: notebook.id, bindingID: UUID(uuidString: binding), recurrenceAnchor: anchorMs.map(Date.init(ms:)),
                                   start: e.start, end: max(e.end, e.start), timeZoneID: e.timeZoneID, titleSnapshot: e.title,
                                   eventState: EventState(rawValue: eventState)!, dismissed: false)
            try upsertSearch(db, recordID: "occ:\(id.uuidString)", notebookID: notebook.id, occurrenceID: id, kind: "title", title: e.title, body: "")
        }
        return ResolvedOccurrence(occurrence: occ, notebook: notebook, reconciliation: state, suggestions: suggestions)
    }

    /// Occurrences whose events vanished from a successfully refreshed range are marked missing; content is kept (§6.2).
    public func markMissing(in range: DateInterval, seenOccurrenceIDs: Set<UUID>, calendarIDs: Set<String>) async throws {
        guard !calendarIDs.isEmpty else { return }
        try await pool.write { db in
            let marks = calendarIDs.map { _ in "?" }.joined(separator: ",")
            var args: [any DatabaseValueConvertible] = [range.start.ms, range.end.ms]
            args.append(contentsOf: calendarIDs.map { $0 as any DatabaseValueConvertible })
            let ids = try String.fetchAll(db, sql: """
                SELECT o.id FROM occurrences o JOIN calendar_bindings b ON o.binding_id = b.id
                WHERE o.start_at_ms >= ? AND o.start_at_ms < ? AND o.event_state = 'active' AND b.calendar_scope IN (\(marks))
                """, arguments: StatementArguments(args))
            for id in ids {
                guard let uuid = UUID(uuidString: id), !seenOccurrenceIDs.contains(uuid) else { continue }
                try db.execute(sql: "UPDATE occurrences SET event_state = 'missing' WHERE id = ?", arguments: [id])
            }
        }
    }

    // MARK: - Repair flow (§7.3, reversible)

    public func linkToExistingNotebook(occurrenceID: UUID, targetNotebookID: UUID) async throws -> UUID {
        let repairID = try await pool.write { db -> UUID in
            guard let occRow = try Row.fetchOne(db, sql: "SELECT * FROM occurrences WHERE id = ?", arguments: [occurrenceID.uuidString]) else { throw StoreError.notFound }
            let occ = Self.occurrence(occRow)
            guard let binding = occ.bindingID else { throw StoreError.notFound }
            guard try Row.fetchOne(db, sql: "SELECT id FROM notebooks WHERE id = ?", arguments: [targetNotebookID.uuidString]) != nil else { throw StoreError.notFound }
            let from = occ.notebookID
            let moved = try String.fetchAll(db, sql: "SELECT id FROM occurrences WHERE binding_id = ?", arguments: [binding.uuidString])
            try Self.move(db, binding: binding.uuidString, occurrenceIDs: moved, to: targetNotebookID.uuidString)
            let id = UUID()
            try db.execute(sql: """
                INSERT INTO identity_repairs(id, binding_id, from_notebook_id, to_notebook_id, moved_occurrence_ids_json, created_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, binding.uuidString, from.uuidString, targetNotebookID.uuidString,
                                 String(decoding: try JSONEncoder().encode(moved), as: UTF8.self), Date().ms])
            return id
        }
        db.notifyChange()
        return repairID
    }

    public func undoRepair(_ repairID: UUID) async throws {
        try await pool.write { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT * FROM identity_repairs WHERE id = ? AND undone_at_ms IS NULL", arguments: [repairID.uuidString]) else { throw StoreError.notFound }
            let moved = try JSONDecoder().decode([String].self, from: Data((r["moved_occurrence_ids_json"] as String).utf8))
            try Self.move(db, binding: r["binding_id"], occurrenceIDs: moved, to: r["from_notebook_id"])
            try db.execute(sql: "UPDATE identity_repairs SET undone_at_ms = ? WHERE id = ?", arguments: [Date().ms, repairID.uuidString])
        }
        db.notifyChange()
    }

    static func move(_ db: Database, binding: String, occurrenceIDs: [String], to notebook: String) throws {
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        try db.execute(sql: "UPDATE calendar_bindings SET notebook_id = ?, reconciliation_state = 'linked' WHERE id = ?", arguments: [notebook, binding])
        for o in occurrenceIDs {
            try db.execute(sql: "UPDATE occurrences SET notebook_id = ? WHERE id = ?", arguments: [notebook, o])
            try db.execute(sql: "UPDATE documents SET notebook_id = ? WHERE occurrence_id = ?", arguments: [notebook, o])
            try db.execute(sql: "UPDATE search_documents SET notebook_id = ? WHERE occurrence_id = ?", arguments: [notebook, o])
        }
    }

    public func pendingRepairs() async throws -> [(id: UUID, createdAt: Date)] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, created_at_ms FROM identity_repairs WHERE undone_at_ms IS NULL ORDER BY created_at_ms DESC LIMIT 20")
                .map { (UUID(uuidString: $0["id"])!, Date(ms: $0["created_at_ms"])) }
        }
    }

    // MARK: - Notebooks & occurrences

    public func notebooks(matching query: String = "", limit: Int = 200) async throws -> [NotebookRecord] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notebooks WHERE display_title LIKE ? ORDER BY updated_at_ms DESC LIMIT ?",
                             arguments: ["%\(query)%", limit]).map(Self.notebook)
        }
    }

    public func notebook(_ id: UUID) async throws -> NotebookRecord? {
        try await pool.read { db in try Row.fetchOne(db, sql: "SELECT * FROM notebooks WHERE id = ?", arguments: [id.uuidString]).map(Self.notebook) }
    }

    public func occurrence(_ id: UUID) async throws -> OccurrenceRecord? {
        try await pool.read { db in try Row.fetchOne(db, sql: "SELECT * FROM occurrences WHERE id = ?", arguments: [id.uuidString]).map(Self.occurrence) }
    }

    public func setDismissed(_ occurrenceID: UUID, _ dismissed: Bool) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE occurrences SET dismissed = ?, updated_at_ms = ? WHERE id = ?", arguments: [dismissed ? 1 : 0, Date().ms, occurrenceID.uuidString])
        }
        db.notifyChange()
    }

    public func dismissedOccurrenceIDs() async throws -> Set<UUID> {
        try await pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM occurrences WHERE dismissed = 1").compactMap(UUID.init(uuidString:)))
        }
    }

    /// Series history page (§6.2: ~50 at a time), with aggregate badges and no transcript bodies (§21.3).
    public func history(notebookID: UUID, before: Date?, limit: Int = 50) async throws -> [OccurrenceSummary] {
        try await pool.read { db in
            try Self.summaries(db, whereSQL: "o.notebook_id = ? AND o.start_at_ms < ?",
                               args: [notebookID.uuidString, (before ?? .distantFuture).ms], order: "o.start_at_ms DESC", limit: limit)
        }
    }

    /// Month history: one bounded query for the visible grid (§5.4).
    public func occurrences(in range: DateInterval) async throws -> [OccurrenceSummary] {
        try await pool.read { db in
            try Self.summaries(db, whereSQL: "o.start_at_ms >= ? AND o.start_at_ms < ?", args: [range.start.ms, range.end.ms],
                               order: "o.start_at_ms ASC", limit: 2000)
        }
    }

    static func summaries(_ db: Database, whereSQL: String, args: [any DatabaseValueConvertible], order: String, limit: Int) throws -> [OccurrenceSummary] {
        let sql = """
            SELECT o.*, n.display_title AS nb_title,
              (SELECT COUNT(*) FROM documents d WHERE d.occurrence_id = o.id AND d.kind = 'notes' AND d.body != '') AS has_notes,
              (SELECT COUNT(*) FROM documents d WHERE d.occurrence_id = o.id AND d.kind = 'talktrack') AS has_tt,
              (SELECT COUNT(*) FROM transcript_segments t JOIN meeting_sessions s ON t.session_id = s.id
                 WHERE s.occurrence_id = o.id AND t.kind = 'speech') AS seg_count,
              (SELECT COUNT(*) FROM summary_versions sv WHERE sv.occurrence_id = o.id) AS sum_count
            FROM occurrences o JOIN notebooks n ON n.id = o.notebook_id
            WHERE \(whereSQL) ORDER BY \(order) LIMIT \(limit)
            """
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { r in
            OccurrenceSummary(occurrence: occurrence(r), notebookTitle: r["nb_title"], hasNotes: (r["has_notes"] as Int) > 0,
                              hasTalktrack: (r["has_tt"] as Int) > 0, transcriptSegments: r["seg_count"], summaryCount: r["sum_count"])
        }
    }

    // MARK: - Documents (§9.2)

    public func document(_ key: DocumentKey) async throws -> DocumentSnapshot {
        try await pool.read { db in try Self.document(db, key) }
    }

    static func document(_ db: Database, _ key: DocumentKey) throws -> DocumentSnapshot {
        let row: Row?
        switch key.scope {
        case .series(let nb):
            row = try Row.fetchOne(db, sql: "SELECT * FROM documents WHERE notebook_id = ? AND occurrence_id IS NULL AND kind = ?", arguments: [nb.uuidString, key.kind.rawValue])
        case .occurrence(_, let occ):
            row = try Row.fetchOne(db, sql: "SELECT * FROM documents WHERE occurrence_id = ? AND kind = ?", arguments: [occ.uuidString, key.kind.rawValue])
        }
        guard let row else { return DocumentSnapshot(key: key, id: nil, body: "", revision: 0, updatedAt: nil) }
        return DocumentSnapshot(key: key, id: UUID(uuidString: row["id"]), body: row["body"], revision: row["revision"], updatedAt: Date(ms: row["updated_at_ms"]))
    }

    /// Commits a document revision. A receipt means the transaction committed (§9.2).
    public func save(_ rev: DocumentRevision, now: Date = Date()) async throws -> SaveReceipt {
        let receipt = try await pool.write { db -> SaveReceipt in
            // Ownership: an occurrence document must belong to the occurrence's notebook (§18.3).
            if case .occurrence(let nb, let occ) = rev.key.scope {
                let owner: String? = try String.fetchOne(db, sql: "SELECT notebook_id FROM occurrences WHERE id = ?", arguments: [occ.uuidString])
                guard owner == nb.uuidString else { throw StoreError.ownershipMismatch }
            } else if try String.fetchOne(db, sql: "SELECT id FROM notebooks WHERE id = ?", arguments: [rev.key.scope.notebookID.uuidString]) == nil {
                throw StoreError.notFound
            }
            let current = try Self.document(db, rev.key)
            let nowMs = now.ms
            var conflict: String?
            let docID: UUID
            let newRevision: Int
            if let id = current.id {
                docID = id
                if current.revision != rev.baseRevision && current.body != rev.body {
                    // Keep both: the other editor's committed text goes to recovery history and is returned.
                    conflict = current.body
                    try db.execute(sql: "INSERT OR REPLACE INTO document_revisions(document_id, revision, body, created_at_ms) VALUES (?, ?, ?, ?)",
                                   arguments: [id.uuidString, current.revision, current.body, nowMs])
                }
                newRevision = current.revision + 1
                try db.execute(sql: "UPDATE documents SET body = ?, revision = ?, updated_at_ms = ? WHERE id = ?",
                               arguments: [rev.body, newRevision, nowMs, id.uuidString])
            } else {
                docID = UUID()
                newRevision = 1
                try db.execute(sql: "INSERT INTO documents(id, notebook_id, occurrence_id, kind, body, revision, updated_at_ms) VALUES (?, ?, ?, ?, ?, 1, ?)",
                               arguments: [docID.uuidString, rev.key.scope.notebookID.uuidString, rev.key.scope.occurrenceID?.uuidString, rev.key.kind.rawValue, rev.body, nowMs])
            }
            // Bounded periodic recovery revisions.
            let lastSnap: Int64? = try Int64.fetchOne(db, sql: "SELECT MAX(created_at_ms) FROM document_revisions WHERE document_id = ?", arguments: [docID.uuidString])
            if lastSnap == nil || Double(nowMs - lastSnap!) / 1000 >= Self.recoverySnapshotInterval {
                try db.execute(sql: "INSERT OR REPLACE INTO document_revisions(document_id, revision, body, created_at_ms) VALUES (?, ?, ?, ?)",
                               arguments: [docID.uuidString, newRevision, rev.body, nowMs])
                try db.execute(sql: """
                    DELETE FROM document_revisions WHERE document_id = ? AND revision NOT IN
                      (SELECT revision FROM document_revisions WHERE document_id = ? ORDER BY revision DESC LIMIT ?)
                    """, arguments: [docID.uuidString, docID.uuidString, Self.recoveryRevisionLimit])
            }
            let title = try String.fetchOne(db, sql: "SELECT display_title FROM notebooks WHERE id = ?", arguments: [rev.key.scope.notebookID.uuidString]) ?? ""
            try Self.upsertSearch(db, recordID: "doc:\(docID.uuidString)", notebookID: rev.key.scope.notebookID, occurrenceID: rev.key.scope.occurrenceID,
                                  kind: rev.key.kind.rawValue + (rev.key.scope.occurrenceID == nil ? "-series" : ""), title: title, body: rev.body)
            try db.execute(sql: "UPDATE notebooks SET updated_at_ms = ? WHERE id = ?", arguments: [nowMs, rev.key.scope.notebookID.uuidString])
            return SaveReceipt(documentID: docID, revision: newRevision, conflictingBody: conflict)
        }
        db.notifyChange()
        return receipt
    }

    public func recoveryRevisions(documentID: UUID) async throws -> [(revision: Int, body: String, createdAt: Date)] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT revision, body, created_at_ms FROM document_revisions WHERE document_id = ? ORDER BY revision DESC", arguments: [documentID.uuidString])
                .map { ($0["revision"], $0["body"], Date(ms: $0["created_at_ms"])) }
        }
    }

    /// Most recent earlier occurrence of the same notebook with non-empty notes ("Copy previous notes", §9.1).
    public func previousNotes(notebookID: UUID, before: Date) async throws -> (OccurrenceRecord, String)? {
        try await pool.read { db in
            guard let r = try Row.fetchOne(db, sql: """
                SELECT o.*, d.body AS doc_body FROM occurrences o JOIN documents d ON d.occurrence_id = o.id AND d.kind = 'notes'
                WHERE o.notebook_id = ? AND o.start_at_ms < ? AND d.body != '' ORDER BY o.start_at_ms DESC LIMIT 1
                """, arguments: [notebookID.uuidString, before.ms]) else { return nil }
            return (Self.occurrence(r), r["doc_body"])
        }
    }

    /// Talktrack "Use series script": delete the occurrence copy (§16.1).
    public func deleteDocument(_ key: DocumentKey) async throws {
        try await pool.write { db in
            let doc = try Self.document(db, key)
            guard let id = doc.id else { return }
            try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM search_documents WHERE record_id = ?", arguments: ["doc:\(id.uuidString)"])
        }
        db.notifyChange()
    }

    // MARK: - Search (§9.3)

    static func upsertSearch(_ db: Database, recordID: String, notebookID: UUID, occurrenceID: UUID?, kind: String, title: String, body: String) throws {
        try db.execute(sql: "DELETE FROM search_documents WHERE record_id = ?", arguments: [recordID])
        try db.execute(sql: "INSERT INTO search_documents(record_id, notebook_id, occurrence_id, content_kind, title, body) VALUES (?, ?, ?, ?, ?, ?)",
                       arguments: [recordID, notebookID.uuidString, occurrenceID?.uuidString, kind, title, body])
    }

    public func search(_ text: String, limit: Int = 50) async throws -> [SearchHit] {
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.joined(separator: " ")
        return try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.record_id, s.notebook_id, s.occurrence_id, s.content_kind,
                       snippet(search_documents, 5, '«', '»', '…', 12) AS body_snip,
                       snippet(search_documents, 4, '«', '»', '…', 12) AS title_snip,
                       n.display_title AS nb_title, o.start_at_ms AS occ_start
                FROM search_documents s
                LEFT JOIN notebooks n ON n.id = s.notebook_id
                LEFT JOIN occurrences o ON o.id = s.occurrence_id
                WHERE search_documents MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [match, limit]).compactMap { r in
                guard let nb = UUID(uuidString: r["notebook_id"] ?? "") else { return nil }
                let start: Int64? = r["occ_start"]
                let bodySnip: String = r["body_snip"] ?? ""
                return SearchHit(recordID: r["record_id"], notebookID: nb, occurrenceID: (r["occurrence_id"] as String?).flatMap(UUID.init(uuidString:)),
                                 contentKind: r["content_kind"], notebookTitle: r["nb_title"] ?? "",
                                 occurrenceDate: start.map(Date.init(ms:)), excerpt: bodySnip.isEmpty ? (r["title_snip"] ?? "") : bodySnip)
            }
        }
    }

    // MARK: - Scoped settings (§19.1)

    public func setting<T: Codable & Sendable>(_ type: T.Type, scope: String, id: String, key: String) async throws -> T? {
        try await pool.read { db in
            guard let json: String = try String.fetchOne(db, sql: "SELECT value_json FROM scoped_settings WHERE scope_kind = ? AND scope_id = ? AND setting_key = ?",
                                                          arguments: [scope, id, key]) else { return nil }
            return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
        }
    }

    public func setSetting<T: Codable & Sendable>(_ value: T?, scope: String, id: String, key: String) async throws {
        try await pool.write { db in
            if let value {
                let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO scoped_settings(scope_kind, scope_id, setting_key, value_json) VALUES (?, ?, ?, ?)
                    ON CONFLICT(scope_kind, scope_id, setting_key) DO UPDATE SET value_json = excluded.value_json, revision = revision + 1
                    """, arguments: [scope, id, key, json])
            } else {
                try db.execute(sql: "DELETE FROM scoped_settings WHERE scope_kind = ? AND scope_id = ? AND setting_key = ?", arguments: [scope, id, key])
            }
        }
        db.notifyChange()
    }

    // MARK: - Automatic action ledger (§11.2)

    /// Reserve-then-act. Throws `actionAlreadyReserved` if any record exists (unique PK).
    public func reserveAction(occurrenceID: UUID, kind: AutomaticActionKind, plannedAt: Date, now: Date = Date()) async throws {
        try await pool.write { db in
            do {
                try db.execute(sql: "INSERT INTO automatic_actions(occurrence_id, kind, state, planned_at_ms, reserved_at_ms) VALUES (?, ?, 'requested', ?, ?)",
                               arguments: [occurrenceID.uuidString, kind.rawValue, plannedAt.ms, now.ms])
            } catch let e as DatabaseError where e.resultCode == .SQLITE_CONSTRAINT {
                throw StoreError.actionAlreadyReserved
            }
        }
    }

    public func finishAction(occurrenceID: UUID, kind: AutomaticActionKind, state: AutomaticActionState, resultCode: String?) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE automatic_actions SET state = ?, finished_at_ms = ?, result_code = ? WHERE occurrence_id = ? AND kind = ?",
                           arguments: [state.rawValue, Date().ms, resultCode, occurrenceID.uuidString, kind.rawValue])
        }
    }

    public func actionStates(kind: AutomaticActionKind) async throws -> [UUID: AutomaticActionState] {
        try await pool.read { db in
            var out: [UUID: AutomaticActionState] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT occurrence_id, state FROM automatic_actions WHERE kind = ?", arguments: [kind.rawValue]) {
                if let id = UUID(uuidString: r["occurrence_id"]), let s = AutomaticActionState(rawValue: r["state"]) { out[id] = s }
            }
            return out
        }
    }

    /// Crash between reservation and opening leaves 'requested' rows: mark them ambiguous (§11.2).
    public func markInterruptedActionsAmbiguous() async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE automatic_actions SET state = 'ambiguous', result_code = 'crash_between_reserve_and_open' WHERE state = 'requested'")
        }
    }

    // MARK: - Deletion & erase (§9.3, §18.4)

    public func deleteOccurrenceContent(_ occurrenceID: UUID) async throws {
        try await pool.write { db in
            let docIDs = try String.fetchAll(db, sql: "SELECT id FROM documents WHERE occurrence_id = ?", arguments: [occurrenceID.uuidString])
            for d in docIDs { try db.execute(sql: "DELETE FROM search_documents WHERE record_id = ?", arguments: ["doc:\(d)"]) }
            try db.execute(sql: "DELETE FROM documents WHERE occurrence_id = ?", arguments: [occurrenceID.uuidString])
            try db.execute(sql: "DELETE FROM search_documents WHERE occurrence_id = ? AND content_kind IN ('transcript', 'summary')", arguments: [occurrenceID.uuidString])
            try db.execute(sql: "DELETE FROM meeting_sessions WHERE occurrence_id = ? AND state NOT IN ('preflight','starting','capturing','stopping')", arguments: [occurrenceID.uuidString])
            try db.execute(sql: "DELETE FROM summary_versions WHERE occurrence_id = ?", arguments: [occurrenceID.uuidString])
            try db.execute(sql: "DELETE FROM durable_jobs WHERE occurrence_id = ?", arguments: [occurrenceID.uuidString])
        }
        db.notifyChange()
    }

    public func deleteNotebook(_ notebookID: UUID) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM search_documents WHERE notebook_id = ?", arguments: [notebookID.uuidString])
            try db.execute(sql: "DELETE FROM scoped_settings WHERE scope_kind = 'notebook' AND scope_id = ?", arguments: [notebookID.uuidString])
            let occs = try String.fetchAll(db, sql: "SELECT id FROM occurrences WHERE notebook_id = ?", arguments: [notebookID.uuidString])
            for o in occs { try db.execute(sql: "DELETE FROM scoped_settings WHERE scope_kind = 'occurrence' AND scope_id = ?", arguments: [o]) }
            try db.execute(sql: "DELETE FROM notebooks WHERE id = ?", arguments: [notebookID.uuidString])
        }
        db.notifyChange()
    }

    public var hasBackups: Bool { !db.listBackups().isEmpty }

    /// Erase all app data files: database, WAL/SHM, revisions, search, backups, jobs, settings. Caller must drop the store afterwards.
    public static func eraseAll(directory: URL) throws {
        let fm = FileManager.default
        for name in ["store.sqlite", "store.sqlite-wal", "store.sqlite-shm", "Backups"] {
            let url = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }
}

extension NotebookRecord {
    static func fetchForBindings(_ db: Database, _ bindingIDs: [String]) throws -> [NotebookRecord] {
        guard !bindingIDs.isEmpty else { return [] }
        let marks = bindingIDs.map { _ in "?" }.joined(separator: ",")
        return try Row.fetchAll(db, sql: "SELECT DISTINCT n.* FROM notebooks n JOIN calendar_bindings b ON b.notebook_id = n.id WHERE b.id IN (\(marks)) ORDER BY n.updated_at_ms DESC",
                                arguments: StatementArguments(bindingIDs)).map(MeetingStore.notebook)
    }
}
