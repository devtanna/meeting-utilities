import Foundation
import GRDB
import Testing
@testable import MeetingCore
@testable import MeetingData

func event(_ title: String, local: String, ext: String? = nil, start: Date, recurring: Bool = false, anchor: Date? = nil,
           calendar: String = "cal-1", cancelled: Bool = false) -> CalendarOccurrenceSnapshot {
    CalendarOccurrenceSnapshot(sourceID: "src-1", calendarID: calendar, calendarItemIdentifier: local, externalIdentifier: ext, eventIdentifier: local + "-ev",
                               title: title, start: start, end: start.addingTimeInterval(1800), originalOccurrenceDate: anchor ?? (recurring ? start : nil),
                               isRecurring: recurring, isCancelled: cancelled)
}

let t0 = Date(timeIntervalSince1970: 1_793_000_000)

@Suite("Identity §7", .serialized)
struct IdentityTests {
    let store: MeetingStore
    init() throws { store = MeetingStore(database: try AppDatabase.temporary()) }

    @Test func sameTitleDifferentSeriesStaySeparate() async throws {
        let a = try await store.resolve(event("Standup", local: "A", ext: "X1", start: t0, recurring: true))
        let b = try await store.resolve(event("Standup", local: "B", ext: "X2", start: t0, recurring: true))
        #expect(a.notebook.id != b.notebook.id)
    }

    @Test func renameKeepsNotebookAndHistoricalTitle() async throws {
        let past = try await store.resolve(event("Old name", local: "A", ext: "X", start: t0.addingTimeInterval(-86400 * 7), recurring: true), now: t0)
        let renamed = try await store.resolve(event("New name", local: "A", ext: "X", start: t0.addingTimeInterval(86400), recurring: true), now: t0)
        #expect(past.notebook.id == renamed.notebook.id)
        #expect(renamed.notebook.displayTitle == "New name")
        let again = try await store.resolve(event("New name", local: "A", ext: "X", start: t0.addingTimeInterval(-86400 * 7), recurring: true), now: t0)
        #expect(again.occurrence.titleSnapshot == "Old name")
    }

    @Test func rescheduleAndDetachedKeepOccurrence() async throws {
        let first = try await store.resolve(event("Sync", local: "A", start: t0, recurring: true))
        let moved = try await store.resolve(event("Sync", local: "A", start: t0.addingTimeInterval(3600), recurring: true, anchor: t0))
        #expect(first.occurrence.id == moved.occurrence.id)
        #expect(moved.occurrence.start == t0.addingTimeInterval(3600))
        let single = try await store.resolve(event("1:1", local: "S", start: t0))
        let singleMoved = try await store.resolve(event("1:1", local: "S", start: t0.addingTimeInterval(7200)))
        #expect(single.occurrence.id == singleMoved.occurrence.id)
    }

    @Test func localIDChurnReconciledByUniqueExternalID() async throws {
        let a = try await store.resolve(event("Review", local: "OLD", ext: "EXT", start: t0, recurring: true))
        let b = try await store.resolve(event("Review", local: "NEW", ext: "EXT", start: t0, recurring: true))
        #expect(a.notebook.id == b.notebook.id && a.occurrence.id == b.occurrence.id)
    }

    @Test func duplicateExternalIDIsAmbiguousNotMerged() async throws {
        let ea = event("Dup", local: "A", ext: "SAME", start: t0, recurring: true)
        let eb = event("Dup", local: "B", ext: "SAME", start: t0, recurring: true)
        let both = try await store.resolveAll([ea, eb])
        let a = both[ea.id]!, b = both[eb.id]!
        #expect(a.notebook.id != b.notebook.id)
        let c = try await store.resolve(event("Dup", local: "C", ext: "SAME", start: t0, recurring: true))
        #expect(c.reconciliation == .ambiguous)
        #expect(c.suggestions.count == 2)
        #expect(![a.notebook.id, b.notebook.id].contains(c.notebook.id))
    }

    @Test func movedCalendarNotMerged() async throws {
        let a = try await store.resolve(event("Plan", local: "A", ext: "E", start: t0, recurring: true, calendar: "cal-1"))
        let b = try await store.resolve(event("Plan", local: "A2", ext: "E", start: t0, recurring: true, calendar: "cal-2"))
        #expect(a.notebook.id != b.notebook.id)
    }

    @Test func manualRepairAndUndo() async throws {
        let a = try await store.resolve(event("Split", local: "A", start: t0, recurring: true))
        let b = try await store.resolve(event("Split (new)", local: "B", start: t0.addingTimeInterval(86400 * 7), recurring: true))
        let key = DocumentKey(scope: .occurrence(notebookID: b.notebook.id, occurrenceID: b.occurrence.id), kind: .notes)
        _ = try await store.save(DocumentRevision(key: key, baseRevision: 0, body: "notes on b"))
        let repair = try await store.linkToExistingNotebook(occurrenceID: b.occurrence.id, targetNotebookID: a.notebook.id)
        let hist = try await store.history(notebookID: a.notebook.id, before: nil)
        #expect(hist.count == 2 && hist.contains { $0.hasNotes })
        let again = try await store.resolve(event("Split (new)", local: "B", start: t0.addingTimeInterval(86400 * 7), recurring: true))
        #expect(again.notebook.id == a.notebook.id)
        try await store.undoRepair(repair)
        #expect(try await store.history(notebookID: b.notebook.id, before: nil).count == 1)
    }

    @Test func cancellationRetainsContent() async throws {
        let a = try await store.resolve(event("C", local: "A", start: t0))
        let key = DocumentKey(scope: .occurrence(notebookID: a.notebook.id, occurrenceID: a.occurrence.id), kind: .notes)
        _ = try await store.save(DocumentRevision(key: key, baseRevision: 0, body: "keep me"))
        let c = try await store.resolve(event("C", local: "A", start: t0, cancelled: true))
        #expect(c.occurrence.eventState == .cancelled)
        #expect(try await store.document(key).body == "keep me")
    }
}

@Suite("Notes & persistence §9, §18", .serialized)
struct PersistenceTests {
    let store: MeetingStore
    init() throws { store = MeetingStore(database: try AppDatabase.temporary()) }

    @Test func lazyCreationAndRevisionOrder() async throws {
        let r = try await store.resolve(event("N", local: "A", start: t0))
        let key = DocumentKey(scope: .occurrence(notebookID: r.notebook.id, occurrenceID: r.occurrence.id), kind: .notes)
        #expect(try await store.document(key).revision == 0)
        let s1 = try await store.save(DocumentRevision(key: key, baseRevision: 0, body: "a"))
        let s2 = try await store.save(DocumentRevision(key: key, baseRevision: s1.revision, body: "ab"))
        #expect(s2.revision == 2 && s2.conflictingBody == nil)
        #expect(try await store.document(key).body == "ab")
    }

    @Test func conflictPreservesBoth() async throws {
        let r = try await store.resolve(event("N", local: "A", start: t0))
        let key = DocumentKey(scope: .series(notebookID: r.notebook.id), kind: .notes)
        _ = try await store.save(DocumentRevision(key: key, baseRevision: 0, body: "window 1"))
        let late = try await store.save(DocumentRevision(key: key, baseRevision: 0, body: "window 2"))
        #expect(late.conflictingBody == "window 1")
        let revs = try await store.recoveryRevisions(documentID: late.documentID)
        #expect(revs.contains { $0.body == "window 1" })
    }

    @Test func ownershipChecked() async throws {
        let a = try await store.resolve(event("A", local: "A", start: t0))
        let b = try await store.resolve(event("B", local: "B", start: t0))
        let bad = DocumentKey(scope: .occurrence(notebookID: a.notebook.id, occurrenceID: b.occurrence.id), kind: .notes)
        await #expect(throws: StoreError.ownershipMismatch) { try await store.save(DocumentRevision(key: bad, baseRevision: 0, body: "x")) }
    }

    @Test func searchAndFTSCleanup() async throws {
        let r = try await store.resolve(event("Budget review", local: "A", start: t0))
        let key = DocumentKey(scope: .occurrence(notebookID: r.notebook.id, occurrenceID: r.occurrence.id), kind: .notes)
        _ = try await store.save(DocumentRevision(key: key, baseRevision: 0, body: "Discuss the quarterly forecast"))
        let hits = try await store.search("forecast")
        #expect(hits.count == 1 && hits[0].excerpt.contains("forecast") && hits[0].notebookTitle == "Budget review")
        #expect(try await store.search("Budget").count >= 1)
        try await store.deleteOccurrenceContent(r.occurrence.id)
        #expect(try await store.search("forecast").isEmpty)
        try await store.deleteNotebook(r.notebook.id)
        #expect(try await store.search("Budget").isEmpty)
    }

    @Test func uniqueActiveSessionAndSegments() async throws {
        let a = try await store.resolve(event("A", local: "A", start: t0))
        let b = try await store.resolve(event("B", local: "B", start: t0))
        let s = try await store.createSession(occurrenceID: a.occurrence.id, mode: .transcript, calendarDeadline: t0.addingTimeInterval(1800), modelID: "m", modelRevision: "r")
        await #expect(throws: StoreError.anotherCaptureActive) {
            _ = try await store.createSession(occurrenceID: b.occurrence.id, mode: .transcript, calendarDeadline: t0, modelID: nil, modelRevision: nil)
        }
        await #expect(throws: StoreError.self) { try await store.transition(sessionID: s.id, to: .capturing) }
        try await store.transition(sessionID: s.id, to: .starting)
        try await store.transition(sessionID: s.id, to: .capturing)
        let seg = TranscriptSegmentRecord(sessionID: s.id, source: "microphone", sequence: 1, kind: .speech, startOffsetMs: 0, endOffsetMs: 900, text: "hello hello")
        #expect(try await store.commitSegment(seg, occurrenceID: a.occurrence.id, notebookID: a.notebook.id))
        // IPC retry: same identity does not duplicate.
        #expect(try await !store.commitSegment(TranscriptSegmentRecord(sessionID: s.id, source: "microphone", sequence: 1, kind: .speech, startOffsetMs: 0, endOffsetMs: 900, text: "hello hello"), occurrenceID: a.occurrence.id, notebookID: a.notebook.id))
        // Older partial never replaces committed.
        var partial = seg; partial.id = UUID(); partial.revision = 2; partial.committed = false; partial.text = "hel"
        #expect(try await !store.commitSegment(partial, occurrenceID: a.occurrence.id, notebookID: a.notebook.id))
        // Overlapping other-source segment is preserved.
        _ = try await store.commitSegment(TranscriptSegmentRecord(sessionID: s.id, source: "system", sequence: 1, kind: .speech, startOffsetMs: 200, endOffsetMs: 700, text: "hi"), occurrenceID: a.occurrence.id, notebookID: a.notebook.id)
        let segs = try await store.segments(sessionID: s.id)
        #expect(segs.count == 2 && segs[0].text == "hello hello")
        // Crash recovery.
        #expect(try await store.recoverInterruptedSessions() == 1)
        #expect(try await store.activeSession() == nil)
        _ = try await store.createSession(occurrenceID: b.occurrence.id, mode: .off, calendarDeadline: t0, modelID: nil, modelRevision: nil)
    }

    @Test func actionLedgerUnique() async throws {
        let a = try await store.resolve(event("A", local: "A", start: t0))
        try await store.reserveAction(occurrenceID: a.occurrence.id, kind: .autoJoin, plannedAt: t0)
        await #expect(throws: StoreError.actionAlreadyReserved) { try await store.reserveAction(occurrenceID: a.occurrence.id, kind: .autoJoin, plannedAt: t0) }
        try await store.markInterruptedActionsAmbiguous()
        #expect(try await store.actionStates(kind: .autoJoin)[a.occurrence.id] == .ambiguous)
    }

    @Test func cascadesOnNotebookDelete() async throws {
        let a = try await store.resolve(event("A", local: "A", start: t0))
        let s = try await store.createSession(occurrenceID: a.occurrence.id, mode: .off, calendarDeadline: t0, modelID: nil, modelRevision: nil)
        try await store.transition(sessionID: s.id, to: .stopped)
        var summary = SummaryV1(); summary.overview = "x"
        try await store.insertSummary(SummaryVersionRecord(id: UUID(), occurrenceID: a.occurrence.id, sourceSessionIDs: [s.id], transcriptDigest: "d", modelID: "m", modelRevision: "r", promptVersion: "p", generationJSON: "{}", result: summary, userEdited: false, createdAt: t0), notebookID: a.notebook.id)
        try await store.deleteNotebook(a.notebook.id)
        let counts = try await store.pool.read { db in
            try ["occurrences", "meeting_sessions", "summary_versions", "documents", "search_documents"].map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")! }
        }
        #expect(counts == [0, 0, 0, 0, 0])
    }

    @Test func migrationBackupAndNewerSchemaRefused() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-mig-\(UUID().uuidString)")
        do {
            let db = try AppDatabase(directory: dir)
            try await db.pool.write { try $0.execute(sql: "UPDATE app_meta SET value = '99' WHERE key = 'min_compatible_schema'") }
        }
        #expect(throws: DatabaseOpenError.self) { _ = try AppDatabase(directory: dir) }
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("store.sqlite").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func monthQueryBadges() async throws {
        let a = try await store.resolve(event("A", local: "A", start: t0))
        let key = DocumentKey(scope: .occurrence(notebookID: a.notebook.id, occurrenceID: a.occurrence.id), kind: .notes)
        _ = try await store.save(DocumentRevision(key: key, baseRevision: 0, body: "n"))
        let month = try await store.occurrences(in: DateInterval(start: t0.addingTimeInterval(-86400), duration: 86400 * 2))
        #expect(month.count == 1 && month[0].hasNotes && month[0].transcriptSegments == 0)
    }

    @Test func exportsIncludeGapsAndSources() async throws {
        let a = try await store.resolve(event("Exp", local: "A", start: t0))
        let s = try await store.createSession(occurrenceID: a.occurrence.id, mode: .transcript, calendarDeadline: t0, modelID: nil, modelRevision: nil)
        _ = try await store.commitSegment(TranscriptSegmentRecord(sessionID: s.id, source: "system", sequence: 1, kind: .speech, startOffsetMs: 0, endOffsetMs: 1000, text: "hello"), occurrenceID: a.occurrence.id, notebookID: a.notebook.id)
        _ = try await store.commitSegment(TranscriptSegmentRecord(sessionID: s.id, source: "system", sequence: 2, kind: .gap, startOffsetMs: 1000, endOffsetMs: 6000, text: ""), occurrenceID: a.occurrence.id, notebookID: a.notebook.id)
        let bundle = try await store.exportOccurrenceBundle(a.occurrence.id)
        #expect(bundle.markdown.contains("Other participants:** hello"))
        #expect(bundle.markdown.contains("[gap"))
        #expect(String(decoding: bundle.json, as: UTF8.self).contains("\"exportSchemaVersion\" : 1"))
    }
}

@Suite("Scoped settings")
struct ScopedSettingsTests {
    @Test func batchedReadMatchesSingleReads() async throws {
        let store = MeetingStore(database: try AppDatabase.temporary())
        try await store.setSetting(true, scope: "occurrence", id: "a", key: "autoJoin")
        try await store.setSetting(false, scope: "occurrence", id: "b", key: "autoJoin")
        try await store.setSetting(true, scope: "notebook", id: "a", key: "autoJoin")      // other scope
        try await store.setSetting(true, scope: "occurrence", id: "c", key: "otherKey")    // other key
        let batch = try await store.settings(Bool.self, scope: "occurrence", ids: ["a", "b", "c", "d", "a"], key: "autoJoin")
        #expect(batch == ["a": true, "b": false])
        for id in ["a", "b", "c", "d"] {
            #expect(try await store.setting(Bool.self, scope: "occurrence", id: id, key: "autoJoin") == batch[id])
        }
        #expect(try await store.settings(Bool.self, scope: "occurrence", ids: [String](), key: "autoJoin").isEmpty)
    }
}
