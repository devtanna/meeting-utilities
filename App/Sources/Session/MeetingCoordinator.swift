import AppKit
import AVFoundation
import Foundation
import InferenceProtocol
import MeetingAudio
import MeetingCore
import MeetingData

enum JoinSource: String { case manual, notification, automatic }

/// Observable state of the one active capture session (§10.5).
struct ActiveSessionState: Equatable {
    var sessionID: UUID
    var occurrenceID: UUID
    var notebookID: UUID
    var title: String
    var capture: CaptureState
    var transcription: TranscriptionState
    var deadline: SessionDeadline
    var sources: [CaptureSource]
    var mode: AutomationMode
    var startedAt: Date?
    var lagSeconds: Double = 0
    var gapCount = 0
    var segmentCount = 0
    var showEndPrompt = false
    var message: String?
}

/// Live input levels for the capture meters. Kept out of `ActiveSessionState` so the ~10 Hz per-source updates
/// redraw only the meters, not every view that observes the coordinator (agenda, open notebooks, menu-bar title).
@MainActor
final class LevelMeters: ObservableObject {
    @Published var levels: [CaptureSource: Float] = [:]
}

struct StartFailureState: Equatable {
    var occurrenceID: UUID
    var failedSource: CaptureSource?
    var reason: String
    var canOfferSingleSource: Bool
}

/// Join sequence (§10.2), capture lifecycle (§10.4–10.6), and transcription pump (§13.5, §14.4).
@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published private(set) var active: ActiveSessionState?
    @Published private(set) var linkStates: [UUID: LinkActionState] = [:]
    @Published var banner: String? { didSet { lastSavedOccurrenceID = nil } }   // stop() sets the ID after the banner
    @Published var startFailure: StartFailureState?
    @Published var pendingSwitch: UUID?                 // "Stop current and start this meeting"
    @Published private(set) var resumable: (occurrenceID: UUID, title: String)?
    @Published var lastFocusResult: FocusResult?
    @Published var lastFailedLink: URL?
    /// The meeting whose transcript was just saved; the agenda banner offers "View Transcript" for it.
    @Published var lastSavedOccurrenceID: UUID?

    private let store: MeetingStore
    private let calendar: CalendarEngine
    private let settings: AppSettings
    private let opener: LinkOpener
    private let focus: FocusController
    private let models: ModelManager
    private let client: InferenceClient
    var summaries: SummaryCoordinator?

    private let capture = CaptureController()
    let meters = LevelMeters()
    private var pumpTask: Task<Void, Never>?
    private var promptTimer: Timer?
    private var deadlineTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var memorySource: DispatchSourceMemoryPressure?
    private var generation = 0
    /// Per-source recognizer outcomes for the running session, saved with it as diagnostics.
    private var recognition: [CaptureSource: RecognitionCounts] = [:]

    init(store: MeetingStore, calendar: CalendarEngine, settings: AppSettings, opener: LinkOpener, focus: FocusController,
         models: ModelManager, client: InferenceClient) {
        self.store = store; self.calendar = calendar; self.settings = settings; self.opener = opener
        self.focus = focus; self.models = models; self.client = client
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt(.sleep) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt(.sessionResigned) }
        })
        client.onInterrupted = { [weak self] in Task { @MainActor in self?.inferenceInterrupted() } }
        let mem = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        mem.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let ev = self.memorySource?.data else { return }
                self.summaries?.memoryPressure(critical: ev.contains(.critical))
                if ev.contains(.critical), self.active?.capture == .capturing {
                    // Stop at a defined boundary with a visible partial result (§14.3).
                    self.banner = "Memory is critically low. Transcription stopped; the partial transcript is saved."
                    Task { await self.stop(reason: .memoryPressure) }
                }
            }
        }
        mem.resume()
        memorySource = mem
    }

    var isCapturing: Bool { active?.capture.isActive == true }

    // MARK: - Join (§10.2)

    func join(_ item: AgendaItem, source: JoinSource, candidate: MeetingLinkCandidate? = nil) async -> Bool {
        guard let resolved = calendar.resolvedOccurrence(for: item) else { return false }
        let occID = resolved.occurrence.id
        setLink(occID, .resolving)
        // 1. Latest occurrence and link; cancellation and freshness.
        let latest = calendar.item(occurrenceID: occID) ?? item
        guard !latest.event.isCancelled else {
            setLink(occID, .failed); banner = "This meeting was cancelled."; return false
        }
        guard let link = candidate ?? latest.primaryLink else {
            setLink(occID, .failed); banner = AppErrorCode.linkMissing.message; return false
        }
        // 3. Open.
        setLink(occID, .opening)
        let outcome = await opener.open(link)
        guard outcome != .failed else {
            setLink(occID, .failed)
            lastFailedLink = link.url
            banner = AppErrorCode.openFailed.message
            Log.opening.error("open failed occurrence=\(occID, privacy: .public)")
            return false
        }
        setLink(occID, .openRequested)
        // Success is silent; only failures and fallbacks need attention.
        banner = outcome == .appMissingUsedBrowser ? "The provider app isn't installed, so the link opened in your browser." : nil
        Log.opening.info("open requested source=\(source.rawValue, privacy: .public)")

        // 4. Independent post-open effects: Focus and transcription preflight.
        if settings.autoFocusEnabled {
            let deadline = latest.event.end
            Task { [focus] in
                let r = await focus.enableIfNoFocus(until: deadline, sessionID: occID)
                await MainActor.run { self.lastFocusResult = r }
            }
        }
        // 6. Automatic transcription only from this app's Join flow, with prior opt-in (§10.3).
        if settings.automationMode.autoTranscribe && settings.automationOptIn {
            if let a = active, a.capture.isActive {
                if a.occurrenceID != occID { pendingSwitch = occID } // never switch silently (§10.5)
            } else {
                await startCapture(occurrenceID: occID, notebookID: resolved.notebook.id, title: latest.event.title,
                                   calendarEnd: latest.event.end, mode: settings.automationMode, manual: false, sources: [.microphone, .system])
            }
        }
        return true
    }

    private func setLink(_ id: UUID, _ s: LinkActionState) { linkStates[id] = s }

    // MARK: - Capture lifecycle

    /// Manual "Start transcription for this meeting". After the scheduled end a new explicit duration is required (§10.4).
    func startManual(occurrenceID: UUID, notebookID: UUID, title: String, calendarEnd: Date, duration: TimeInterval?, sources: [CaptureSource] = [.microphone, .system]) async {
        let end = duration.map { Date().addingTimeInterval($0) } ?? calendarEnd
        await startCapture(occurrenceID: occurrenceID, notebookID: notebookID, title: title, calendarEnd: end,
                           mode: settings.automationMode == .off ? .transcript : settings.automationMode, manual: true, sources: sources)
    }

    func switchToPending() async {
        guard let target = pendingSwitch, let item = calendar.item(occurrenceID: target), let r = calendar.resolvedOccurrence(for: item) else { return }
        pendingSwitch = nil
        await stop(reason: .replaced) // finalize the old session first (§10.5)
        await startCapture(occurrenceID: target, notebookID: r.notebook.id, title: item.event.title, calendarEnd: item.event.end,
                           mode: settings.automationMode == .off ? .transcript : settings.automationMode, manual: true, sources: [.microphone, .system])
    }

    func startCapture(occurrenceID: UUID, notebookID: UUID, title: String, calendarEnd: Date, mode: AutomationMode, manual: Bool, sources: [CaptureSource]) async {
        if let a = active, a.capture.isActive {
            if a.occurrenceID == occurrenceID { return } // rejoin never creates a second stream
            pendingSwitch = occurrenceID; return
        }
        startFailure = nil
        resumable = nil
        let speech = models.entry(.speechToText)
        let check = SessionPreflight.check(PreflightInput(
            optedIn: settings.automationOptIn, speechModelReady: models.isReady(.speechToText),
            microphoneAuthorized: !sources.contains(.microphone) || MicrophoneSource.authorization == .authorized,
            sourcesTested: settings.sourcesTested, deadline: calendarEnd, now: Date(), activeCapture: nil, occurrenceID: occurrenceID, isManual: manual))
        if let check {
            if check == .microphoneDenied && MicrophoneSource.authorization == .notDetermined {
                if await MicrophoneSource.requestAccess() {
                    return await startCapture(occurrenceID: occurrenceID, notebookID: notebookID, title: title, calendarEnd: calendarEnd, mode: mode, manual: manual, sources: sources)
                }
            }
            startFailure = StartFailureState(occurrenceID: occurrenceID, failedSource: check == .microphoneDenied ? .microphone : nil,
                                             reason: Self.message(check), canOfferSingleSource: check == .microphoneDenied)
            Log.capture.info("preflight failed \(check.rawValue, privacy: .public)")
            return
        }
        let record: MeetingSessionRecord
        do {
            record = try await store.createSession(occurrenceID: occurrenceID, mode: mode, calendarDeadline: calendarEnd, modelID: speech?.id, modelRevision: speech?.artifactRevision)
        } catch {
            startFailure = StartFailureState(occurrenceID: occurrenceID, failedSource: nil, reason: "Another transcription is already running.", canOfferSingleSource: false)
            return
        }
        generation += 1
        let gen = generation
        recognition = [:]
        meters.levels = [:]
        active = ActiveSessionState(sessionID: record.id, occurrenceID: occurrenceID, notebookID: notebookID, title: title, capture: .preflight,
                                    transcription: .ready, deadline: SessionDeadline(calendarDeadline: calendarEnd), sources: sources, mode: mode)
        do {
            try await store.transition(sessionID: record.id, to: .starting)
            update { $0.capture = .starting; $0.message = "Starting…" }
            // Load the speech model first so a model failure never leaves capture running unseen.
            guard let speech, let dir = Optional(models.installDirectory(speech)) else { throw AppError(.speechModelMissing) }
            models.setInUse(.speechToText, true)
            _ = try await client.load(kind: .speech, modelID: speech.id, revision: speech.artifactRevision, directory: dir)
            guard gen == generation else { return }
            let stream = try capture.start(CaptureConfiguration(sessionID: record.id, sources: sources, microphoneDeviceUID: settings.microphoneUID))
            try await store.transition(sessionID: record.id, to: .capturing)
            update { $0.capture = .capturing; $0.transcription = .processingChunks; $0.startedAt = Date(); $0.message = nil }
            Log.capture.info("capture running session=\(record.id, privacy: .public)")
            runPump(stream: stream, sessionID: record.id, occurrenceID: occurrenceID, notebookID: notebookID, generation: gen)
            scheduleDeadlineTimers()
        } catch let failure as CaptureStartFailure {
            await failStart(record.id, occurrenceID, source: failure.source, reason: "\(failure.source.label) audio could not start (\(String(describing: failure.error))).", offerSingle: sources.count > 1)
        } catch {
            await failStart(record.id, occurrenceID, source: nil, reason: (error as? AppError)?.message ?? "The transcription service could not start.", offerSingle: false)
        }
    }

    private func failStart(_ sessionID: UUID, _ occurrenceID: UUID, source: CaptureSource?, reason: String, offerSingle: Bool) async {
        capture.stop()
        try? await store.transition(sessionID: sessionID, to: .failed, reason: .sourceLost)
        models.setInUse(.speechToText, false)
        active = nil
        startFailure = StartFailureState(occurrenceID: occurrenceID, failedSource: source, reason: reason, canOfferSingleSource: offerSingle)
    }

    static func message(_ f: PreflightFailure) -> String {
        switch f {
        case .speechModelMissing: AppErrorCode.speechModelMissing.message
        case .microphoneDenied: "Microphone access is off. Allow it in System Settings › Privacy & Security › Microphone."
        case .systemAudioUnavailable: "System audio capture is unavailable."
        case .microphoneUnavailable: "No microphone is available."
        case .sourcesNotTested: "Test the microphone and system audio in Settings › Transcription before automatic capture."
        case .deadlinePassed: "This meeting's scheduled end has passed. Choose a duration to start manually."
        case .anotherCaptureActive: "Another transcription is running."
        case .notOptedIn: "Automatic transcription is not enabled."
        }
    }

    func extend(by seconds: TimeInterval = SessionDeadline.defaultExtension) {
        guard var a = active else { return }
        a.deadline.extend(by: seconds, now: Date())
        a.showEndPrompt = false
        active = a
        Task { try? await store.updateDeadlines(sessionID: a.sessionID, calendar: a.deadline.calendarDeadline, userExtended: a.deadline.userExtendedDeadline) }
        scheduleDeadlineTimers()
        // Extending transcription does not extend Do Not Disturb (§10.4).
    }

    /// Calendar extended/shortened while capturing (§10.4).
    func calendarDidUpdate() {
        guard var a = active, a.capture == .capturing, let item = calendar.item(occurrenceID: a.occurrenceID) else { return }
        switch a.deadline.applyCalendarEnd(item.event.end, now: Date()) {
        case .unchanged: return
        case .updated:
            active = a
            Task { try? await store.updateDeadlines(sessionID: a.sessionID, calendar: a.deadline.calendarDeadline, userExtended: a.deadline.userExtendedDeadline) }
            scheduleDeadlineTimers()
        case .stopNow:
            a.message = "The meeting was shortened in your calendar, so transcription stopped."
            active = a
            Task { await stop(reason: .calendarShortened) }
        }
    }

    private func scheduleDeadlineTimers() {
        promptTimer?.invalidate(); deadlineTimer?.invalidate()
        guard let a = active else { return }
        let promptIn = a.deadline.promptAt.timeIntervalSinceNow
        if promptIn > 0 {
            promptTimer = Timer.scheduledTimer(withTimeInterval: promptIn, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.update { $0.showEndPrompt = true } }
            }
        } else {
            update { $0.showEndPrompt = true }
        }
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: max(0.5, a.deadline.effective.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let a = self.active, a.deadline.effective <= Date().addingTimeInterval(1) else { self?.scheduleDeadlineTimers(); return }
                Task { await self.stop(reason: .scheduledEnd) }
            }
        }
        deadlineTimer?.tolerance = 0.5
    }

    private func update(_ f: (inout ActiveSessionState) -> Void) {
        guard var a = active else { return }
        f(&a)
        if a != active { active = a }
    }

    /// Stop: release both sources, drain captured audio, persist text, then queue a summary if enabled (§10.4).
    func stop(reason: StopReason) async {
        guard let a = active, a.capture == .capturing || a.capture == .starting else { return }
        promptTimer?.invalidate(); deadlineTimer?.invalidate()
        let interrupted = [.sleep, .sessionResigned, .sourceLost, .permissionRevoked, .inferenceFailed].contains(reason)
        try? await store.transition(sessionID: a.sessionID, to: .stopping, reason: reason)
        update { $0.capture = .stopping; $0.transcription = .draining; $0.showEndPrompt = false }
        capture.stop()                         // flushes in-progress speech into the stream, then finishes it
        if !interrupted { await pumpTask?.value } else { pumpTask?.cancel(); await client.cancel(jobID: nil, sessionID: a.sessionID) }
        pumpTask = nil
        await saveDiagnostics(sessionID: a.sessionID)
        try? await store.transition(sessionID: a.sessionID, to: interrupted ? .interrupted : .stopped, reason: reason)
        if interrupted { try? await store.transition(sessionID: a.sessionID, to: .stopped, reason: reason) }
        models.setInUse(.speechToText, false)
        await client.unloadModels()
        let final = active
        active = nil
        if interrupted { resumable = (a.occurrenceID, a.title) }
        banner = interrupted ? AppErrorCode.sessionInterrupted.message : "Transcription saved"
        lastSavedOccurrenceID = a.occurrenceID
        Log.capture.info("capture stopped reason=\(reason.rawValue, privacy: .public) segments=\(final?.segmentCount ?? 0, privacy: .public)")
        if a.capture == .capturing, (final?.segmentCount ?? 0) > 0, a.mode == .transcriptAndSummary {
            summaries?.enqueue(occurrenceID: a.occurrenceID, notebookID: a.notebookID)
        }
        summaries?.captureEnded()
    }

    private func interrupt(_ reason: StopReason) {
        guard active?.capture == .capturing else { return }
        Task { await stop(reason: reason) }
    }

    /// Manual Resume after an interruption: a new session segment; the missing interval is never reconstructed (§10.6).
    func resume() async {
        guard let r = resumable, let item = calendar.item(occurrenceID: r.occurrenceID), let res = calendar.resolvedOccurrence(for: item) else {
            resumable = nil; return
        }
        resumable = nil
        await startManual(occurrenceID: r.occurrenceID, notebookID: res.notebook.id, title: r.title,
                          calendarEnd: max(item.event.end, Date().addingTimeInterval(15 * 60)), duration: nil)
    }

    private func inferenceInterrupted() {
        guard let a = active, a.capture == .capturing else { return }
        update { $0.message = AppErrorCode.inferenceCrashed.message }
        // One reconnection attempt within the visible session and queue budget (§22.2).
        Task {
            guard let speech = models.entry(.speechToText) else { return }
            do {
                _ = try await client.load(kind: .speech, modelID: speech.id, revision: speech.artifactRevision, directory: models.installDirectory(speech))
                update { $0.message = nil }
            } catch {
                await stop(reason: .inferenceFailed)
            }
        }
    }

    // MARK: - Transcription pump

    struct RecognitionCounts: Codable { var sent = 0, recognized = 0, empty = 0, failed = 0 }

    /// What each source delivered and what the recognizer made of it (§21 diagnostics; no audio or text).
    struct SessionDiagnostics: Codable {
        var sources: [String: Entry]
        struct Entry: Codable {
            var device: String
            var audioSeconds: Double
            var peakDB: Float
            var utterances: Int
            var restarts: Int
            var stalls: Int
            var recognized: Int
            var empty: Int
            var failed: Int
        }
    }

    private func saveDiagnostics(sessionID: UUID) async {
        let stats = capture.stats()
        var entries: [String: SessionDiagnostics.Entry] = [:]
        for (source, s) in stats {
            let r = recognition[source] ?? RecognitionCounts()
            entries[source.rawValue] = .init(device: s.device, audioSeconds: (s.audioSeconds * 10).rounded() / 10, peakDB: (s.peakDB * 10).rounded() / 10,
                                             utterances: s.utterances, restarts: s.restarts, stalls: s.stalls,
                                             recognized: r.recognized, empty: r.empty, failed: r.failed)
            Log.capture.info("session \(source.rawValue, privacy: .public) sent=\(r.sent, privacy: .public) recognized=\(r.recognized, privacy: .public) empty=\(r.empty, privacy: .public) failed=\(r.failed, privacy: .public)")
        }
        guard let data = try? JSONEncoder().encode(SessionDiagnostics(sources: entries)), let json = String(data: data, encoding: .utf8) else { return }
        try? await store.setCoverage(sessionID: sessionID, json: json)
    }

    private struct Pending { var source: CaptureSource; var utterance: Utterance; var bytes: Int }

    private func runPump(stream: AsyncStream<CaptureEvent>, sessionID: UUID, occurrenceID: UUID, notebookID: UUID, generation gen: Int) {
        let origin = capture.originHostTime
        let budget = capture.budget
        let store = self.store, client = self.client
        pumpTask = Task { [weak self] in
            var queues: [CaptureSource: [Pending]] = [:]
            var inFlight: [CaptureSource: Task<Void, Never>] = [:]
            var sequence: [CaptureSource: Int] = [:]
            var lastText: [CaptureSource: (text: String, end: Double, forced: Bool)] = [:]
            var lastLevel: [CaptureSource: Date] = [:]
            let maxBacklogSeconds = 60.0

            @MainActor func commitGap(_ source: CaptureSource, start: Double, end: Double) async {
                let seq = (sequence[source] ?? 0) + 1; sequence[source] = seq
                let seg = TranscriptSegmentRecord(sessionID: sessionID, source: source.rawValue, sequence: seq, kind: .gap,
                                                  startOffsetMs: max(0, Int((start - origin) * 1000)), endOffsetMs: max(0, Int((end - origin) * 1000)), text: "")
                _ = try? await store.commitSegment(seg, occurrenceID: occurrenceID, notebookID: notebookID)
                self?.update { $0.gapCount += 1 }
            }

            @MainActor func dispatch(_ source: CaptureSource) {
                guard inFlight[source] == nil, var q = queues[source], !q.isEmpty else { return }
                let item = q.removeFirst(); queues[source] = q
                let seq = (sequence[source] ?? 0) + 1; sequence[source] = seq
                let u = item.utterance
                let header = ChunkHeader(sessionID: sessionID, jobID: sessionID, generation: gen, sequence: seq, source: source == .microphone ? .microphone : .system,
                                         sampleRate: 16_000, frameCount: u.samples.count, hostTimeStartSeconds: u.startHostTime, hostTimeEndSeconds: u.endHostTime)
                budget.set("inflight-\(source.rawValue)", bytes: item.bytes)
                inFlight[source] = Task { @MainActor in
                    defer { inFlight[source] = nil; budget.set("inflight-\(source.rawValue)", bytes: 0); dispatch(source) }
                    let startMs = max(0, Int((u.startHostTime - origin) * 1000)), endMs = max(startMs, Int((u.endHostTime - origin) * 1000))
                    self?.recognition[source, default: .init()].sent += 1
                    do {
                        let r = try await client.transcribe(header: header, samples: u.samples)
                        // Reject late results from cancelled/replaced sessions (§4.3).
                        guard r.generation == gen, r.sessionID == sessionID, self?.generation == gen || self?.active == nil else { return }
                        guard r.ok else {
                            self?.recognition[source, default: .init()].failed += 1
                            Log.capture.error("transcribe failed source=\(source.rawValue, privacy: .public) code=\(r.errorCode ?? "", privacy: .public)")
                            // The chunk's audio is already gone; record a gap instead of pretending (§13.6).
                            let s = TranscriptSegmentRecord(sessionID: sessionID, source: source.rawValue, sequence: seq, kind: .gap, startOffsetMs: startMs, endOffsetMs: endMs, text: "")
                            _ = try? await store.commitSegment(s, occurrenceID: occurrenceID, notebookID: notebookID)
                            self?.update { $0.gapCount += 1 }
                            return
                        }
                        var text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let prev = lastText[source], prev.forced, u.startHostTime < prev.end { text = OverlapDedupe.trimLeadingOverlap(previous: prev.text, next: text) }
                        lastText[source] = (r.text, u.endHostTime, u.forcedSplit)
                        guard !text.isEmpty else { self?.recognition[source, default: .init()].empty += 1; return }
                        self?.recognition[source, default: .init()].recognized += 1
                        let s = TranscriptSegmentRecord(sessionID: sessionID, source: source.rawValue, sequence: seq, kind: .speech, startOffsetMs: startMs, endOffsetMs: endMs, text: text)
                        if (try? await store.commitSegment(s, occurrenceID: occurrenceID, notebookID: notebookID)) == true {
                            self?.update { $0.segmentCount += 1; $0.lagSeconds = max(0, HostTime.now() - u.endHostTime) }
                        }
                    } catch {
                        self?.recognition[source, default: .init()].failed += 1
                        Log.capture.error("transcribe threw source=\(source.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
                        let s = TranscriptSegmentRecord(sessionID: sessionID, source: source.rawValue, sequence: seq, kind: .gap, startOffsetMs: startMs, endOffsetMs: endMs, text: "")
                        _ = try? await store.commitSegment(s, occurrenceID: occurrenceID, notebookID: notebookID)
                        self?.update { $0.gapCount += 1 }
                    }
                }
            }

            for await event in stream {
                switch event {
                case .utterance(let source, let u):
                    let bytes = u.samples.count * 4
                    queues[source, default: []].append(Pending(source: source, utterance: u, bytes: bytes))
                    // Bounded backlog: per-source seconds and the global 32 MiB budget; drop oldest with a gap marker (§13.5).
                    while let q = queues[source], q.count > 1,
                          (q.reduce(0.0) { $0 + Double($1.utterance.samples.count) / 16_000 } > maxBacklogSeconds || budget.isExceeded) {
                        let dropped = queues[source]!.removeFirst()
                        await commitGap(source, start: dropped.utterance.startHostTime, end: dropped.utterance.endHostTime)
                        self?.banner = AppErrorCode.queueOverflow.message
                    }
                    budget.set("queue-\(source.rawValue)", bytes: queues[source]!.reduce(0) { $0 + $1.bytes })
                    dispatch(source)
                case .level(let source, let db):
                    // ≤10 Hz UI updates per source (§21.3); a shared throttle starved the second meter.
                    if Date().timeIntervalSince(lastLevel[source] ?? .distantPast) > 0.1 {
                        lastLevel[source] = Date()
                        if self?.active != nil { self?.meters.levels[source] = db }
                    }
                case .sourceDropped(let source, let secs, let at):
                    await commitGap(source, start: at - secs, end: at)
                case .sourceFailed(let source, _):
                    // A disappeared source stops the session and the interval is identified (§13.3).
                    self?.update { $0.message = "\(source.label) audio was lost." }
                    await commitGap(source, start: HostTime.now(), end: HostTime.now())
                    Task { await self?.stop(reason: .sourceLost) }
                case .sourceRestarted(let source):
                    self?.update { $0.message = "\(source == .microphone ? "Microphone" : "System audio") restarted after a device change; capture continued." }
                }
            }
            // Drain: wait for in-flight chunks, then process what is queued (captured audio only).
            for source in CaptureSource.allCases {
                while true {
                    if let t = inFlight[source] { await t.value; continue }
                    if queues[source]?.isEmpty ?? true { break }
                    dispatch(source)
                }
            }
            budget.set("queue-microphone", bytes: 0); budget.set("queue-system", bytes: 0)
            self?.update { $0.transcription = ($0.gapCount > 0) ? .partial : .complete }
        }
    }
}
