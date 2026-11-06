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
    var onInterrupted: (@Sendable () -> Void)?

    init() {
        serviceName = (Bundle.main.bundleIdentifier ?? "com.devtanna.meetingutils") + ".InferenceService"
    }

    var isConnected: Bool { lock.withLock { connection != nil } }

    private func proxy(_ onError: @escaping @Sendable (Error) -> Void) -> InferenceServiceXPC? {
        lock.withLock {
            idleTimer?.cancel(); idleTimer = nil
            if connection == nil {
                let c = NSXPCConnection(serviceName: serviceName)
                c.remoteObjectInterface = NSXPCInterface(with: InferenceServiceXPC.self)
                c.interruptionHandler = { [weak self] in
                    Log.inference.error("inference service interrupted")
                    self?.onInterrupted?()
                }
                c.invalidationHandler = { [weak self] in
                    self?.lock.withLock { self?.connection = nil }
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
        lock.withLock {
            idleTimer?.cancel(); idleTimer = nil
            guard inFlight == 0 else { return }
            connection?.invalidate()
            connection = nil
        }
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
        return r
    }

    func unloadModels() async {
        _ = try? await call(SimpleResponse.self) { p, reply in p.unloadModels(Data(), reply: reply) }
    }

    func transcribe(header: ChunkHeader, samples: [Float]) async throws -> ChunkResult {
        let h = Wire.encode(header), pcm = Wire.pcmData(samples)
        return try await call(ChunkResult.self) { p, reply in p.transcribe(h, pcm: pcm, reply: reply) }
    }

    func generate(_ req: GenerateRequest) async throws -> GenerateResult {
        try await call(GenerateResult.self) { p, reply in p.generate(Wire.encode(req), reply: reply) }
    }

    func cancel(jobID: UUID?, sessionID: UUID?) async {
        _ = try? await call(SimpleResponse.self) { p, reply in p.cancel(Wire.encode(CancelRequest(jobID: jobID, sessionID: sessionID)), reply: reply) }
    }
}
