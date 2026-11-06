import Foundation
import MeetingCore

public enum NotebookKind: String, Sendable, Codable { case series, single }

public struct NotebookRecord: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var displayTitle: String
    public var kind: NotebookKind
    public var createdAt: Date
    public var updatedAt: Date
}

public enum EventState: String, Sendable, Codable { case active, cancelled, missing }

public struct OccurrenceRecord: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var notebookID: UUID
    public var bindingID: UUID?
    public var recurrenceAnchor: Date?
    public var start: Date
    public var end: Date
    public var timeZoneID: String?
    public var titleSnapshot: String
    public var eventState: EventState
    public var dismissed: Bool
}

public enum ReconciliationState: String, Sendable, Codable { case linked, missing, ambiguous }

public struct ResolvedOccurrence: Sendable, Equatable {
    public var occurrence: OccurrenceRecord
    public var notebook: NotebookRecord
    public var reconciliation: ReconciliationState
    /// Ranked suggestions when identity was ambiguous; never auto-merged (§7.2 step 5).
    public var suggestions: [NotebookRecord]
}

public enum DocumentKind: String, Sendable, Codable, CaseIterable { case notes, talktrack }

public enum DocumentScope: Sendable, Equatable, Hashable, Codable {
    case series(notebookID: UUID)
    case occurrence(notebookID: UUID, occurrenceID: UUID)

    public var notebookID: UUID {
        switch self { case .series(let n), .occurrence(let n, _): n }
    }
    public var occurrenceID: UUID? {
        if case .occurrence(_, let o) = self { return o }
        return nil
    }
}

public struct DocumentKey: Sendable, Equatable, Hashable, Codable {
    public var scope: DocumentScope
    public var kind: DocumentKind
    public init(scope: DocumentScope, kind: DocumentKind) { self.scope = scope; self.kind = kind }
}

public struct DocumentSnapshot: Sendable, Equatable {
    public var key: DocumentKey
    public var id: UUID?
    public var body: String
    public var revision: Int        // 0 = not yet created (lazy creation)
    public var updatedAt: Date?

    public init(key: DocumentKey, id: UUID?, body: String, revision: Int, updatedAt: Date?) {
        self.key = key; self.id = id; self.body = body; self.revision = revision; self.updatedAt = updatedAt
    }
}

/// A save attempt against `baseRevision` (optimistic concurrency, §9.2).
public struct DocumentRevision: Sendable, Equatable {
    public var key: DocumentKey
    public var baseRevision: Int
    public var body: String
    public init(key: DocumentKey, baseRevision: Int, body: String) { self.key = key; self.baseRevision = baseRevision; self.body = body }
}

public struct SaveReceipt: Sendable, Equatable {
    public var documentID: UUID
    public var revision: Int
    /// When another editor committed first, its text is preserved in revision history and returned here.
    public var conflictingBody: String?
}

public struct OccurrenceSummary: Sendable, Equatable, Identifiable {
    public var id: UUID { occurrence.id }
    public var occurrence: OccurrenceRecord
    public var notebookTitle: String
    public var hasNotes: Bool
    public var hasTalktrack: Bool
    public var transcriptSegments: Int
    public var summaryCount: Int
}

public struct MeetingSessionRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var occurrenceID: UUID
    public var state: CaptureState
    public var automationMode: AutomationMode
    public var actualStart: Date?
    public var actualEnd: Date?
    public var calendarDeadline: Date
    public var userExtendedDeadline: Date?
    public var stopReason: StopReason?
    public var modelID: String?
    public var modelRevision: String?
    public var coverageJSON: String
}

public enum SegmentKind: String, Sendable, Codable { case speech, gap }

public struct TranscriptSegmentRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var source: String     // microphone | system | combined
    public var sequence: Int
    public var revision: Int
    public var kind: SegmentKind
    public var startOffsetMs: Int
    public var endOffsetMs: Int
    public var text: String
    public var committed: Bool

    public init(id: UUID = UUID(), sessionID: UUID, source: String, sequence: Int, revision: Int = 1, kind: SegmentKind,
                startOffsetMs: Int, endOffsetMs: Int, text: String, committed: Bool = true) {
        self.id = id; self.sessionID = sessionID; self.source = source; self.sequence = sequence; self.revision = revision
        self.kind = kind; self.startOffsetMs = startOffsetMs; self.endOffsetMs = endOffsetMs; self.text = text; self.committed = committed
    }

    public var sourceLabel: String {
        switch source {
        case "microphone": "You"
        case "system": "Other participants"
        default: "Combined"
        }
    }
}

public struct SummaryVersionRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var occurrenceID: UUID
    public var sourceSessionIDs: [UUID]
    public var transcriptDigest: String
    public var modelID: String
    public var modelRevision: String
    public var promptVersion: String
    public var generationJSON: String
    public var result: SummaryV1
    public var userEdited: Bool
    public var createdAt: Date

    public init(id: UUID, occurrenceID: UUID, sourceSessionIDs: [UUID], transcriptDigest: String, modelID: String, modelRevision: String,
                promptVersion: String, generationJSON: String, result: SummaryV1, userEdited: Bool, createdAt: Date) {
        self.id = id; self.occurrenceID = occurrenceID; self.sourceSessionIDs = sourceSessionIDs; self.transcriptDigest = transcriptDigest
        self.modelID = modelID; self.modelRevision = modelRevision; self.promptVersion = promptVersion; self.generationJSON = generationJSON
        self.result = result; self.userEdited = userEdited; self.createdAt = createdAt
    }
}

public struct DurableJobRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var occurrenceID: UUID
    public var state: String         // queued | running | complete | failed | cancelled
    public var inputRevision: String
    public var progressJSON: String
    public var attemptCount: Int
    public var updatedAt: Date
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public var id: String { recordID + contentKind }
    public var recordID: String
    public var notebookID: UUID
    public var occurrenceID: UUID?
    public var contentKind: String
    public var notebookTitle: String
    public var occurrenceDate: Date?
    public var excerpt: String
}

public enum StoreError: Error, Sendable, Equatable {
    case notFound
    case ownershipMismatch
    case actionAlreadyReserved
    case anotherCaptureActive
    case invalidTransition(String)
}
