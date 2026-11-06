import Foundation
import InferenceProtocol
import MeetingCore
import MeetingData

/// Durable, bounded-context summary jobs (§14.2, §14.5–14.7). Runs only when capture is idle; text-only checkpoints.
@MainActor
final class SummaryCoordinator: ObservableObject {
    struct Progress: Codable, Equatable {
        var digest: String
        var sectionCount: Int
        var partials: [SummaryV1]
        var notebookID: UUID
    }

    @Published private(set) var states: [UUID: SummaryState] = [:]          // by occurrence
    @Published private(set) var messages: [UUID: String] = [:]
    @Published private(set) var deferredReason: String?

    private let store: MeetingStore
    private let models: ModelManager
    private let client: InferenceClient
    private let settings: AppSettings
    var isCaptureActive: () -> Bool = { false }
    private var running: Task<Void, Never>?
    private var runningJob: UUID?
    private var pausedForMemory = false

    static let maxTokensPerResponse = SummaryPrompt.responseBudgetTokens

    init(store: MeetingStore, models: ModelManager, client: InferenceClient, settings: AppSettings) {
        self.store = store; self.models = models; self.client = client; self.settings = settings
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.kick() }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.kick() }
        }
    }

    func start() {
        Task {
            try? await store.requeueInterruptedJobs()   // resume after crash from text checkpoints
            for j in (try? await store.jobs(states: ["queued"])) ?? [] { states[j.occurrenceID] = .queued }
            kick()
        }
    }

    func enqueue(occurrenceID: UUID, notebookID: UUID) {
        Task {
            let existing = (try? await store.jobs(occurrenceID: occurrenceID))?.first { $0.state == "queued" || $0.state == "running" }
            if existing == nil {
                let segs = try await allSegments(occurrenceID)
                guard !segs.isEmpty else { messages[occurrenceID] = "No transcript to summarize."; return }
                let digest = MeetingStore.transcriptDigest(segs)
                let job = try await store.createJob(occurrenceID: occurrenceID, inputRevision: digest)
                try await store.updateJob(job.id, state: "queued", progressJSON: encode(Progress(digest: digest, sectionCount: 0, partials: [], notebookID: notebookID)))
            }
            states[occurrenceID] = .queued
            kick()
        }
    }

    func cancel(occurrenceID: UUID) {
        Task {
            for j in (try? await store.jobs(occurrenceID: occurrenceID)) ?? [] where j.state == "queued" || j.state == "running" {
                try? await store.updateJob(j.id, state: "cancelled")
                if runningJob == j.id { running?.cancel(); await client.cancel(jobID: j.id, sessionID: nil) }
            }
            states[occurrenceID] = .cancelled
        }
    }

    func retry(occurrenceID: UUID, notebookID: UUID) {
        Task {
            if let j = (try? await store.jobs(occurrenceID: occurrenceID))?.first(where: { $0.state == "failed" || $0.state == "cancelled" }) {
                try? await store.updateJob(j.id, state: "queued")
                states[occurrenceID] = .queued
                kick()
            } else {
                enqueue(occurrenceID: occurrenceID, notebookID: notebookID)
            }
        }
    }

    func captureEnded() { kick() }

    func memoryPressure(critical: Bool) {
        pausedForMemory = true
        if critical, let id = runningJob { running?.cancel(); Task { await client.cancel(jobID: id, sessionID: nil) } }
        Task { try? await Task.sleep(for: .seconds(120)); pausedForMemory = false; kick() }
    }

    /// Summaries are deferred during capture, serious thermal pressure, low-power mode, or memory pressure (§14.3, §21.3).
    private var deferral: String? {
        if isCaptureActive() { return "Waiting for transcription to finish" }
        if pausedForMemory { return "Paused: memory pressure" }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical { return "Paused: Mac is hot" }
        if settings.deferSummariesOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled { return "Paused: Low Power Mode" }
        return nil
    }

    func kick() {
        guard running == nil else { return }
        deferredReason = deferral
        guard deferredReason == nil else { return }
        running = Task { [weak self] in
            await self?.runQueue()
            self?.running = nil
            self?.runningJob = nil
        }
    }

    private func runQueue() async {
        while let job = (try? await store.jobs(states: ["queued"]))?.first {
            if let d = deferral { deferredReason = d; return }
            await run(job)
            if Task.isCancelled { return }
        }
    }

    private func allSegments(_ occurrenceID: UUID) async throws -> [TranscriptSegmentRecord] {
        try await store.transcript(occurrenceID: occurrenceID).flatMap(\.segments)
    }

    private func run(_ job: DurableJobRecord) async {
        let occ = job.occurrenceID
        runningJob = job.id
        guard let entry = models.entry(.summary), models.isReady(.summary) else {
            try? await store.updateJob(job.id, state: "failed")
            states[occ] = .failed
            messages[occ] = AppErrorCode.summaryModelMissing.message
            return
        }
        guard var progress = decode(job.progressJSON) else { try? await store.updateJob(job.id, state: "failed"); states[occ] = .failed; return }
        try? await store.updateJob(job.id, state: "running", incrementAttempt: true)
        states[occ] = .loadingModel
        do {
            let segments = try await allSegments(occ)
            let digest = MeetingStore.transcriptDigest(segments)
            if digest != progress.digest { progress = Progress(digest: digest, sectionCount: 0, partials: [], notebookID: progress.notebookID) }
            // Stable short IDs for citations, gaps preserved as explicit coverage (§14.4, §14.5).
            let summarySegments = segments.enumerated().map { i, s in
                SummarySegment(id: "S\(i + 1)", source: s.sourceLabel, offsetMs: s.startOffsetMs, endOffsetMs: s.endOffsetMs, text: s.text, isGap: s.kind == .gap)
            }
            let gapNotes = segments.filter { $0.kind == .gap }.map { g in
                "No transcript for \(Self.stamp(g.startOffsetMs))–\(Self.stamp(g.endOffsetMs)) (\(g.sourceLabel))"
            }
            let known = Set(summarySegments.filter { !$0.isGap }.map(\.id))
            let sections = SummaryPrompt.sections(summarySegments)
            progress.sectionCount = sections.count

            // Speech model is released before the summary model loads (§14.3).
            await client.unloadModels()
            _ = try await client.load(kind: .summary, modelID: entry.id, revision: entry.artifactRevision, directory: models.installDirectory(entry))
            models.setInUse(.summary, true)
            defer { models.setInUse(.summary, false) }
            states[occ] = .generating
            var lastGen: GenerateResult?
            for i in progress.partials.count..<sections.count {
                try Task.checkCancellation()
                messages[occ] = sections.count > 1 ? "Summarizing section \(i + 1) of \(sections.count)…" : "Summarizing…"
                let prompt = SummaryPrompt.sectionPrompt(meetingTitle: nil, segments: sections[i], sectionIndex: i, sectionCount: sections.count)
                do {
                    let (partial, gen) = try await generateValidated(job.id, prompt: prompt)
                    lastGen = gen
                    let (validated, _) = SummaryValidator.validate(partial, knownSegmentIDs: Set(sections[i].map(\.id)), gapNotes: [])
                    progress.partials.append(validated)
                } catch let e as AppError where e.code == .summaryInvalid {
                    // Never silently drop part of the meeting: record it as a visible coverage gap (§14.7).
                    var placeholder = SummaryV1()
                    let first = sections[i].first.map { Self.stamp($0.offsetMs) } ?? "?", last = sections[i].last.map { Self.stamp($0.endOffsetMs) } ?? "?"
                    placeholder.coverageWarnings = ["The section \(first)–\(last) could not be summarized; see the transcript."]
                    progress.partials.append(placeholder)
                }
                try await store.updateJob(job.id, state: "running", progressJSON: encode(progress)) // checkpoint per section
            }
            var final: SummaryV1
            if progress.partials.count == 1 {
                final = progress.partials[0]
            } else {
                messages[occ] = "Combining sections…"
                // Deterministic merge keeps every decision/action reference; the model writes only the overview.
                let req = GenerateRequest(jobID: job.id, system: SummaryPrompt.system, user: SummaryPrompt.overviewPrompt(partials: progress.partials, coverageNotes: gapNotes),
                                          maxTokens: 600, maxKVSize: SummaryPrompt.contextBudgetTokens)
                let r = try await client.generate(req)
                let ov = r.ok ? SummaryPrompt.decodeOverview(r.text) : nil
                lastGen = r
                final = SummaryMerge.merge(progress.partials, overview: ov?.overview, discussionPoints: ov?.discussionPoints)
            }
            let sectionNotes = Set(progress.partials.flatMap(\.coverageWarnings).filter { $0.hasPrefix("The section ") })
            let (validated, report) = SummaryValidator.validate(final, knownSegmentIDs: known, gapNotes: gapNotes, appCoverageNotes: sectionNotes)
            let sessions = try await store.sessions(occurrenceID: occ).map(\.id)
            let generation: [String: String] = [
                "temperature": "0.2", "topP": "0.9", "contextBudget": "\(SummaryPrompt.contextBudgetTokens)", "sections": "\(sections.count)",
                "removedCitations": "\(report.removedCitations)", "droppedItems": "\(report.droppedItems)",
                "generatedTokens": "\(lastGen?.generatedTokens ?? 0)", "coverage": gapNotes.isEmpty ? "complete" : "partial",
            ]
            try await store.insertSummary(SummaryVersionRecord(
                id: UUID(), occurrenceID: occ, sourceSessionIDs: sessions, transcriptDigest: digest, modelID: entry.id, modelRevision: entry.artifactRevision,
                promptVersion: SummaryPrompt.version, generationJSON: String(decoding: try JSONEncoder().encode(generation), as: UTF8.self),
                result: validated, userEdited: false, createdAt: Date()), notebookID: progress.notebookID)
            try await store.updateJob(job.id, state: "complete", progressJSON: encode(progress))
            states[occ] = .complete
            messages[occ] = nil
            Log.inference.info("summary complete sections=\(sections.count, privacy: .public)")
        } catch is CancellationError {
            states[occ] = .cancelled
        } catch {
            try? await store.updateJob(job.id, state: "failed", progressJSON: encode(progress))
            states[occ] = .failed
            messages[occ] = (error as? AppError)?.message ?? AppErrorCode.summaryInvalid.message
            Log.inference.error("summary failed")
        }
    }

    /// One generation plus at most one bounded repair (§22.2).
    private func generateValidated(_ jobID: UUID, prompt: String) async throws -> (SummaryV1, GenerateResult) {
        let req = GenerateRequest(jobID: jobID, system: SummaryPrompt.system, user: prompt, maxTokens: Self.maxTokensPerResponse, maxKVSize: SummaryPrompt.contextBudgetTokens)
        let r = try await client.generate(req)
        guard r.ok else {
            if r.errorCode == "cancelled" { throw CancellationError() }
            throw AppError(.summaryInvalid, detail: r.errorCode)
        }
        if let s = SummaryPrompt.decode(r.text) { return (s, r) }
        if let repaired = SummaryPrompt.repair(r.text), let s = SummaryPrompt.decode(repaired) { return (s, r) }
        throw AppError(.summaryInvalid)
    }

    /// User edits create an edited version; generated versions never overwrite them silently (§14.7).
    func saveEdited(_ summary: SummaryV1, basedOn base: SummaryVersionRecord, notebookID: UUID) async {
        try? await store.insertSummary(SummaryVersionRecord(
            id: UUID(), occurrenceID: base.occurrenceID, sourceSessionIDs: base.sourceSessionIDs, transcriptDigest: base.transcriptDigest,
            modelID: base.modelID, modelRevision: base.modelRevision, promptVersion: base.promptVersion, generationJSON: base.generationJSON,
            result: summary, userEdited: true, createdAt: Date()), notebookID: notebookID)
    }

    static func stamp(_ ms: Int) -> String {
        let t = ms / 1000
        return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    private func encode(_ p: Progress) -> String { String(decoding: (try? JSONEncoder().encode(p)) ?? Data("{}".utf8), as: UTF8.self) }
    private func decode(_ s: String) -> Progress? { try? JSONDecoder().decode(Progress.self, from: Data(s.utf8)) }
}
