// Embedded on-demand inference XPC service (§4.1, §14.3).
// - Owns MLX state; the host never links MLX.
// - One heavy job at a time on a serial executor.
// - No database access, no networking code, no arbitrary commands or downloads.
// - Unloads models after 30 s idle and exits when the host drops its connection.

import Foundation
import InferenceEngines
import InferenceProtocol
import os

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "InferenceService", category: "inference")

final class ServiceState: @unchecked Sendable {
    let queue = DispatchQueue(label: "inference.serial", qos: .userInitiated)
    let speech = ParakeetEngine()
    let summary = QwenEngine()
    var speechModel: (id: String, revision: String)?
    var summaryModel: (id: String, revision: String)?
    var cancelledJobs = Set<UUID>()
    var cancelledSessions = Set<UUID>()
    var lastSequence: [String: Int] = [:]      // "\(session)|\(source)" -> highest accepted sequence
    var idleWork: DispatchWorkItem?
    var connections = 0
    let lock = NSLock()

    func isCancelled(job: UUID) -> Bool { lock.withLock { cancelledJobs.contains(job) } }

    func touch() {
        idleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.speech.unload(); self.summary.unload()
            self.speechModel = nil; self.summaryModel = nil
            log.info("idle grace elapsed; models unloaded")
        }
        idleWork = w
        queue.asyncAfter(deadline: .now() + 30, execute: w)
    }

    /// Model directories must live inside the app's Application Support Models folder.
    func isAllowedModelPath(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath().path
        return resolved.hasPrefix(support + "/") && resolved.contains("/Models/")
    }
}

let state = ServiceState()

final class InferenceServiceHandler: NSObject, InferenceServiceXPC {
    func ping(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let req = Wire.decode(PingRequest.self, request)
        state.queue.async {
            state.touch()
            let probe = req?.runMLXProbe == true ? MLXProbe.run() : nil
            var loaded: [String] = []
            if let m = state.speechModel { loaded.append("\(m.id)@\(m.revision)") }
            if let m = state.summaryModel { loaded.append("\(m.id)@\(m.revision)") }
            let resp = PingResponse(protocolVersion: InferenceProtocolVersion.current,
                                    serviceVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                                    mlxProbe: probe, loadedModels: loaded, activeMemoryBytes: MLXProbe.activeMemoryBytes(),
                                    peakMemoryBytes: MLXProbe.peakMemoryBytes(), processID: getpid())
            reply(Wire.encode(resp))
        }
    }

    func loadModel(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let req = Wire.decode(LoadModelRequest.self, request), req.protocolVersion == InferenceProtocolVersion.current else {
            reply(Wire.encode(SimpleResponse(ok: false, errorCode: "bad_request"))); return
        }
        guard state.isAllowedModelPath(req.directoryPath) else {
            reply(Wire.encode(SimpleResponse(ok: false, errorCode: "model_path_rejected"))); return
        }
        state.queue.async {
            state.touch()
            let dir = URL(fileURLWithPath: req.directoryPath, isDirectory: true)
            do {
                switch req.kind {
                case .speech:
                    if state.speechModel?.revision == req.revision && state.speech.isLoaded { reply(Wire.encode(SimpleResponse(ok: true, elapsedSeconds: 0))); return }
                    // Speech has priority; never hold both models at once (§14.3).
                    state.summary.unload(); state.summaryModel = nil
                    let t = try state.speech.load(directory: dir)
                    state.speechModel = (req.modelID, req.revision)
                    log.info("speech model loaded in \(t, privacy: .public)s")
                    reply(Wire.encode(SimpleResponse(ok: true, elapsedSeconds: t)))
                case .summary:
                    if state.summaryModel?.revision == req.revision && state.summary.isLoaded { reply(Wire.encode(SimpleResponse(ok: true, elapsedSeconds: 0))); return }
                    state.speech.unload(); state.speechModel = nil
                    let sem = DispatchSemaphore(value: 0)
                    let box = ResultBox()
                    Task.detached {
                        do { box.value = .success(try await state.summary.load(directory: dir)) } catch { box.value = .failure(error) }
                        sem.signal()
                    }
                    sem.wait()
                    let t = try box.value!.get()
                    state.summaryModel = (req.modelID, req.revision)
                    log.info("summary model loaded in \(t, privacy: .public)s")
                    reply(Wire.encode(SimpleResponse(ok: true, elapsedSeconds: t)))
                }
            } catch {
                log.error("model load failed kind=\(req.kind.rawValue, privacy: .public)")
                reply(Wire.encode(SimpleResponse(ok: false, errorCode: "load_failed")))
            }
        }
    }

    func unloadModels(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        state.queue.async {
            state.speech.unload(); state.summary.unload()
            state.speechModel = nil; state.summaryModel = nil
            reply(Wire.encode(SimpleResponse(ok: true)))
        }
    }

    func transcribe(_ header: Data, pcm: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let h = Wire.decode(ChunkHeader.self, header) else {
            reply(Wire.encode(SimpleResponse(ok: false, errorCode: "bad_header"))); return
        }
        func fail(_ code: String) {
            reply(Wire.encode(ChunkResult(sessionID: h.sessionID, generation: h.generation, sequence: h.sequence, source: h.source, ok: false,
                                          errorCode: code, text: "", segments: [], computeSeconds: 0)))
        }
        // Validate sizes/ranges before allocating sample storage (§4.1).
        if let v = h.validate(pcmByteCount: pcm.count) { fail("invalid_\(v.rawValue)"); return }
        let key = "\(h.sessionID)|\(h.source.rawValue)"
        let stale = state.lock.withLock { () -> Bool in
            if state.cancelledSessions.contains(h.sessionID) { return true }
            if let last = state.lastSequence[key], h.sequence <= last { return true }
            state.lastSequence[key] = h.sequence
            return false
        }
        if stale { fail("duplicate_or_stale"); return }
        state.queue.async {
            state.touch()
            guard state.speech.isLoaded else { fail("model_not_loaded"); return }
            if state.lock.withLock({ state.cancelledSessions.contains(h.sessionID) }) { fail("cancelled"); return }
            let samples = Wire.samples(pcm)
            do {
                let r = try state.speech.transcribe(samples: samples, sampleRate: h.sampleRate)
                reply(Wire.encode(ChunkResult(sessionID: h.sessionID, generation: h.generation, sequence: h.sequence, source: h.source, ok: true,
                                              errorCode: nil, text: r.text,
                                              segments: r.segments.map { ChunkSegment(text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) },
                                              computeSeconds: r.elapsedSeconds)))
            } catch {
                fail("transcribe_failed")
            }
        }
    }

    func generate(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let req = Wire.decode(GenerateRequest.self, request), req.protocolVersion == InferenceProtocolVersion.current, req.isWithinBounds else {
            reply(Wire.encode(GenerateResult(jobID: UUID(), ok: false, errorCode: "bad_request", text: "", promptTokens: 0, generatedTokens: 0, elapsedSeconds: 0)))
            return
        }
        state.queue.async {
            state.touch()
            guard state.summary.isLoaded else {
                reply(Wire.encode(GenerateResult(jobID: req.jobID, ok: false, errorCode: "model_not_loaded", text: "", promptTokens: 0, generatedTokens: 0, elapsedSeconds: 0)))
                return
            }
            let sem = DispatchSemaphore(value: 0)
            let box = GenBox()
            let jobID = req.jobID
            Task.detached {
                do {
                    box.value = .success(try await state.summary.generate(system: req.system, user: req.user, maxTokens: req.maxTokens, maxKVSize: req.maxKVSize,
                                                                          isCancelled: { state.isCancelled(job: jobID) }))
                } catch { box.value = .failure(error) }
                sem.signal()
            }
            sem.wait()
            state.touch()
            switch box.value! {
            case .success(let g):
                reply(Wire.encode(GenerateResult(jobID: req.jobID, ok: true, errorCode: nil, text: String(g.text.prefix(InferenceProtocolVersion.maxTextBytes)),
                                                 promptTokens: g.promptTokens, generatedTokens: g.generatedTokens, elapsedSeconds: g.elapsedSeconds)))
            case .failure(let e):
                let code = (e as? EngineError).map { $0.description } ?? "generate_failed"
                reply(Wire.encode(GenerateResult(jobID: req.jobID, ok: false, errorCode: code, text: "", promptTokens: 0, generatedTokens: 0, elapsedSeconds: 0)))
            }
        }
    }

    func cancel(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let req = Wire.decode(CancelRequest.self, request) else { reply(Wire.encode(SimpleResponse(ok: false, errorCode: "bad_request"))); return }
        state.lock.withLock {
            if let j = req.jobID { state.cancelledJobs.insert(j) }
            if let s = req.sessionID { state.cancelledSessions.insert(s) }
        }
        reply(Wire.encode(SimpleResponse(ok: true)))
    }
}

final class ResultBox: @unchecked Sendable { var value: Result<Double, Error>? }
final class GenBox: @unchecked Sendable { var value: Result<LLMGeneration, Error>? }

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Validate the expected peer: only the containing app's signing identifier (§4.1).
        let hostID = (Bundle.main.bundleIdentifier ?? "").replacingOccurrences(of: ".InferenceService", with: "")
        c.setCodeSigningRequirement("identifier \"\(hostID)\"")
        c.exportedInterface = NSXPCInterface(with: InferenceServiceXPC.self)
        c.exportedObject = InferenceServiceHandler()
        state.lock.withLock { state.connections += 1 }
        c.invalidationHandler = {
            let remaining = state.lock.withLock { state.connections -= 1; return state.connections }
            if remaining <= 0 {
                log.info("last connection closed; exiting to release model memory")
                exit(0)
            }
        }
        c.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
