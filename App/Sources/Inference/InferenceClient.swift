import Foundation
import InferenceProtocol
import MeetingCore

enum InferenceClientError: Error, Sendable { case connectionFailed, serviceError(String), badReply }

/// XPC client for the on-demand InferenceService (§4.1). The connection is created lazily for an explicit model
/// validation or AI job and invalidated after 30 s idle so the service exits and releases model memory (§14.3).
final class InferenceClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var idleTimer: DispatchSourceTimer?
    private var inFlight = 0
    private let serviceName: String
    private var resident: ModelKind?
    private var keep: ModelKind?
    var onInterrupted: (@Sendable () -> Void)?
    /// Called (on an arbitrary queue) whenever `residentModel` changes.
    var onResidentChange: (@Sendable () -> Void)?

    init() {
        serviceName = (Bundle.main.bundleIdentifier ?? "com.devtanna.meetingutils") + ".InferenceService"
    }

    var isConnected: Bool { lock.withLock { connection != nil } }

    /// The model the service holds, as far as this client knows. The service holds at most one at a time and drops it
    /// when it goes idle, crashes, or loses this connection (§14.3).
    var residentModel: ModelKind? { lock.withLock { resident } }

    /// A model the user asked to keep in memory from Settings; workflows that would otherwise release it leave it loaded.
    var keptModel: ModelKind? {
        get { lock.withLock { keep } }
        set { lock.withLock { keep = newValue } }
    }

    private func setResident(_ kind: ModelKind?) {
        let changed = lock.withLock { () -> Bool in
            guard resident != kind else { return false }
            resident = kind
            return true
        }
        if changed { onResidentChange?() }
    }

    private func proxy(_ onError: @escaping @Sendable (Error) -> Void) -> InferenceServiceXPC? {
        lock.withLock {
            idleTimer?.cancel(); idleTimer = nil
            if connection == nil {
                let c = NSXPCConnection(serviceName: serviceName)
                c.remoteObjectInterface = NSXPCInterface(with: InferenceServiceXPC.self)
                c.interruptionHandler = { [weak self] in
                    Log.inference.error("inference service interrupted")
                    self?.setResident(nil)          // a restarted service starts empty
                    self?.onInterrupted?()
                }
                c.invalidationHandler = { [weak self, weak c] in
                    guard let self else { return }
                    // Only clear our state if this is still the current connection (a newer one may already exist).
                    let current = self.lock.withLock { () -> Bool in
                        guard self.connection == nil || self.connection === c else { return false }
                        self.connection = nil
                        return true
                    }
                    if current { self.setResident(nil) }
                }
                c.resume()
                connection = c
            }
            inFlight += 1
            return connection?.remoteObjectProxyWithErrorHandler(onError) as? InferenceServiceXPC
        }
    }

    private func finished() {
        lock.withLock {
            inFlight -= 1
            guard inFlight == 0 else { return }
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + 30)
            t.setEventHandler { [weak self] in self?.invalidate() }
            t.resume()
            idleTimer = t
        }
    }

    func invalidate() {
        let dropped = lock.withLock { () -> Bool in
            idleTimer?.cancel(); idleTimer = nil
            guard inFlight == 0, let c = connection else { return false }
            c.invalidate()
            connection = nil
            return true
        }
        // The service exits when its last connection closes, taking any loaded model with it.
        if dropped { setResident(nil) }
    }

    private func call<R: Decodable & Sendable>(_ type: R.Type, _ body: @escaping (InferenceServiceXPC, @escaping @Sendable (Data) -> Void) -> Void) async throws -> R {
        defer { finished() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<R, Error>) in
            let once = OSAllocatedUnfairLockBox(false)
            guard let p = proxy({ _ in if once.swap(true) == false { cont.resume(throwing: InferenceClientError.connectionFailed) } }) else {
                if once.swap(true) == false { cont.resume(throwing: InferenceClientError.connectionFailed) }
                return
            }
            body(p) { data in
                guard once.swap(true) == false else { return }
                if let r = Wire.decode(R.self, data) { cont.resume(returning: r) } else { cont.resume(throwing: InferenceClientError.badReply) }
            }
        }
    }

    func ping(probe: Bool) async throws -> PingResponse {
        try await call(PingResponse.self) { p, reply in p.ping(Wire.encode(PingRequest(runMLXProbe: probe)), reply: reply) }
    }

    func load(kind: ModelKind, modelID: String, revision: String, directory: URL) async throws -> SimpleResponse {
        let req = LoadModelRequest(kind: kind, modelID: modelID, revision: revision, directoryPath: directory.path)
        let r = try await call(SimpleResponse.self) { p, reply in p.loadModel(Wire.encode(req), reply: reply) }
        if !r.ok { throw InferenceClientError.serviceError(r.errorCode ?? "load_failed") }
        setResident(kind)                   // loading one model releases the other inside the service
        return r
    }

    func unloadModels() async {
        _ = try? await call(SimpleResponse.self) { p, reply in p.unloadModels(Data(), reply: reply) }
        setResident(nil)
    }

    func transcribe(header: ChunkHeader, samples: [Float]) async throws -> ChunkResult {
        let h = Wire.encode(header), pcm = Wire.pcmData(samples)
        let r = try await call(ChunkResult.self) { p, reply in p.transcribe(h, pcm: pcm, reply: reply) }
        if !r.ok, r.errorCode == "model_not_loaded" { setResident(nil) }
        return r
    }

    func generate(_ req: GenerateRequest) async throws -> GenerateResult {
        let r = try await call(GenerateResult.self) { p, reply in p.generate(Wire.encode(req), reply: reply) }
        if !r.ok, r.errorCode == "model_not_loaded" { setResident(nil) }
        return r
    }

    func generationProgress(jobID: UUID) async -> GenerationProgress? {
        try? await call(GenerationProgress.self) { p, reply in p.generationProgress(Wire.encode(GenerationProgressRequest(jobID: jobID)), reply: reply) }
    }

    func cancel(jobID: UUID?, sessionID: UUID?) async {
        _ = try? await call(SimpleResponse.self) { p, reply in p.cancel(Wire.encode(CancelRequest(jobID: jobID, sessionID: sessionID)), reply: reply) }
    }
}
