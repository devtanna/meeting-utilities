import Foundation
import MeetingCore

/// Markdown + versioned JSON export of an occurrence or notebook (§9.3).
public struct ExportBundle: Sendable {
    public var markdown: String
    public var json: Data
}

public struct OccurrenceExportV1: Codable, Sendable {
    public struct Segment: Codable, Sendable {
        public var source: String, kind: String, startOffsetMs: Int, endOffsetMs: Int, text: String
        /// The other side's speaker, when the call app showed who was talking.
        public var speaker: String?
    }
    public struct Session: Codable, Sendable {
        public var id: UUID, state: String, start: Date?, end: Date?, stopReason: String?, segments: [Segment]
    }
    public var exportSchemaVersion = 1
    public var occurrenceID: UUID
    public var notebookTitle: String
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZone: String?
    public var seriesNotes: String
    public var notes: String
    public var talktrack: String
    public var sessions: [Session]
    public var summary: SummaryV1?
    public var summaryModel: String?
}

public struct NotebookExportV1: Codable, Sendable {
    public var exportSchemaVersion = 1
    public var notebookID: UUID
    public var title: String
    public var seriesNotes: String
    public var seriesTalktrack: String
    public var occurrences: [OccurrenceExportV1]
}

extension MeetingStore {
    public func exportOccurrence(_ occurrenceID: UUID) async throws -> (OccurrenceExportV1, String) {
        guard let occ = try await occurrence(occurrenceID), let nb = try await notebook(occ.notebookID) else { throw StoreError.notFound }
        let series = try await document(DocumentKey(scope: .series(notebookID: nb.id), kind: .notes)).body
        let notes = try await document(DocumentKey(scope: .occurrence(notebookID: nb.id, occurrenceID: occ.id), kind: .notes)).body
        let tt = try await document(DocumentKey(scope: .occurrence(notebookID: nb.id, occurrenceID: occ.id), kind: .talktrack)).body
        let transcript = try await transcript(occurrenceID: occ.id)
        let summary = try await summaries(occurrenceID: occ.id).first
        let ex = OccurrenceExportV1(
            occurrenceID: occ.id, notebookTitle: nb.displayTitle, title: occ.titleSnapshot, start: occ.start, end: occ.end, timeZone: occ.timeZoneID,
            seriesNotes: series, notes: notes, talktrack: tt,
            sessions: transcript.map { s, segs in
                .init(id: s.id, state: s.state.rawValue, start: s.actualStart, end: s.actualEnd, stopReason: s.stopReason?.rawValue,
                      segments: segs.map { .init(source: $0.source, kind: $0.kind.rawValue, startOffsetMs: $0.startOffsetMs, endOffsetMs: $0.endOffsetMs, text: $0.text, speaker: $0.speaker) })
            },
            summary: summary?.result, summaryModel: summary.map { "\($0.modelID)@\($0.modelRevision)" })
        return (ex, Self.markdown(ex))
    }

    public func exportNotebook(_ notebookID: UUID) async throws -> ExportBundle {
        guard let nb = try await notebook(notebookID) else { throw StoreError.notFound }
        let series = try await document(DocumentKey(scope: .series(notebookID: nb.id), kind: .notes)).body
        let seriesTT = try await document(DocumentKey(scope: .series(notebookID: nb.id), kind: .talktrack)).body
        var occs: [OccurrenceExportV1] = []
        var md = "# \(nb.displayTitle)\n\n"
        if !series.isEmpty { md += "## Series notes\n\n\(series)\n\n" }
        if !seriesTT.isEmpty { md += "## Talktrack (series)\n\n\(seriesTT)\n\n" }
        for o in try await history(notebookID: notebookID, before: nil, limit: 10_000) {
            let (ex, omd) = try await exportOccurrence(o.occurrence.id)
            occs.append(ex)
            md += omd.replacingOccurrences(of: "\n# ", with: "\n## ") + "\n---\n\n"
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let json = try enc.encode(NotebookExportV1(notebookID: nb.id, title: nb.displayTitle, seriesNotes: series, seriesTalktrack: seriesTT, occurrences: occs))
        return ExportBundle(markdown: md, json: json)
    }

    public func exportOccurrenceBundle(_ occurrenceID: UUID) async throws -> ExportBundle {
        let (ex, md) = try await exportOccurrence(occurrenceID)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return ExportBundle(markdown: md, json: try enc.encode(ex))
    }

    static func markdown(_ ex: OccurrenceExportV1) -> String {
        let df = DateFormatter()
        df.dateStyle = .full; df.timeStyle = .short
        var md = "# \(ex.title)\n\n_\(df.string(from: ex.start))_ · \(ex.notebookTitle)\n\n"
        if !ex.notes.isEmpty { md += "## Notes\n\n\(ex.notes)\n\n" }
        if !ex.talktrack.isEmpty { md += "## Talktrack\n\n\(ex.talktrack)\n\n" }
        if let s = ex.summary { md += "## Summary\n\n" + s.markdown().replacingOccurrences(of: "## ", with: "### ") + "\n" }
        if !ex.sessions.isEmpty {
            md += "## Transcript\n\n"
            for s in ex.sessions {
                md += "_Session \(s.start.map { df.string(from: $0) } ?? "not started") – \(s.state)\(s.stopReason.map { " (\($0))" } ?? "")_\n\n"
                for seg in s.segments {
                    let t = seg.startOffsetMs / 1000
                    let stamp = String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                    if seg.kind == "gap" {
                        md += "- `\(stamp)` **[gap — no transcript for \((seg.endOffsetMs - seg.startOffsetMs) / 1000)s]**\n"
                    } else {
                        md += "- `\(stamp)` **\(seg.source == "microphone" ? "You" : seg.speaker ?? "Other participants"):** \(seg.text)\n"
                    }
                }
                md += "\n"
            }
        }
        return md
    }
}
