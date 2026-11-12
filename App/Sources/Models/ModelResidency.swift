import Foundation
import InferenceProtocol
import MeetingCore

/// Which on-device model is loaded in the inference service right now, plus manual Load/Unload from Settings → Models.
///
/// Normally models load on demand and are released 30 s after their last use (§14.3). Load keeps one model warm
/// (pinged every 10 s so neither the service's nor the client's idle timer fires) until the user unloads it, another
/// job needs the memory for the other model (the service only ever holds one), the service restarts, or memory runs
/// critically low.
@MainActor
final class ModelResidency: ObservableObject {
    enum Activity: Equatable { case loading, unloading }

    @Published private(set) var resident: ModelKind?
    @Published private(set) var kept: ModelKind?
    @Published private(set) var activity: [ModelKind: Activity] = [:]
    @Published private(set) var errors: [ModelKind: String] = [:]
    /// MLX memory in use by the service, refreshed by the keep-alive ping while a model is kept loaded.
    @Published private(set) var memoryBytes: Int?

    private let client: InferenceClient
    private let models: ModelManager
    private var keepAlive: Task<Void, Never>?
    private var memorySource: DispatchSourceMemoryPressure?

    init(client: InferenceClient, models: ModelManager) {
        self.client = client
        self.models = models
        resident = client.residentModel
        client.onResidentChange = { [weak self] in Task { @MainActor in self?.sync() } }
        let mem = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
        mem.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.memoryCritical() } }
        mem.resume()
        memorySource = mem
    }

    static func kind(_ purpose: ModelCatalogEntry.Purpose) -> ModelKind { purpose == .speechToText ? .speech : .summary }

    /// Transcription or a summary is using this model right now, so it can't be unloaded.
    func isInUse(_ kind: ModelKind) -> Bool { models.state(kind == .speech ? .speechToText : .summary) == .inUse }

    /// Loading one model evicts the other, so Load is refused while the other model is doing work.
    func blockedReason(_ kind: ModelKind) -> String? {
        let other: ModelKind = kind == .speech ? .summary : .speech
        guard isInUse(other) else { return nil }
        return other == .speech ? "Transcription is running; load this after it stops." : "A summary is being written; load this after it finishes."
    }

    func load(_ entry: ModelCatalogEntry) async {
        let kind = Self.kind(entry.purpose)
        guard activity[kind] == nil, models.states[entry.id]?.isReady == true else { return }
        if let reason = blockedReason(kind) { errors[kind] = reason; return }
        errors[kind] = nil
        activity[kind] = .loading
        defer { activity[kind] = nil }
        do {
            _ = try await client.load(kind: kind, modelID: entry.id, revision: entry.artifactRevision, directory: models.installDirectory(entry))
            kept = kind
            client.keptModel = kind
            startKeepAlive()
            Log.models.info("model kept loaded kind=\(kind.rawValue, privacy: .public)")
        } catch {
            errors[kind] = Self.describe(error)
        }
        sync()
    }

    func unload(_ kind: ModelKind) async {
        guard activity[kind] == nil, !isInUse(kind) else { return }
        release()
        errors[kind] = nil
        guard client.residentModel == kind else { return }
        activity[kind] = .unloading
        await client.unloadModels()
        activity[kind] = nil
        sync()
        Log.models.info("model unloaded kind=\(kind.rawValue, privacy: .public)")
    }

    /// Called before a model's files are removed: never keep weights loaded that are no longer on disk.
    func forget(_ kind: ModelKind) async {
        if kept == kind { release() }
        if client.residentModel == kind, !isInUse(kind) { await client.unloadModels() }
        sync()
    }

    private func sync() {
        resident = client.residentModel
        // The kept model was evicted (the other model loaded, the service restarted, or it went idle): stop keeping it.
        if let k = kept, resident != k, activity[k] == nil { release() }
    }

    private func release() {
        kept = nil
        client.keptModel = nil
        keepAlive?.cancel(); keepAlive = nil
        memoryBytes = nil
    }

    private func startKeepAlive() {
        keepAlive?.cancel()
        keepAlive = Task { @MainActor [weak self, client] in
            while !Task.isCancelled {
                if let r = try? await client.ping(probe: false) {
                    self?.memoryBytes = r.loadedModels.isEmpty ? nil : r.activeMemoryBytes
                    if r.loadedModels.isEmpty, self?.kept != nil { self?.release(); self?.sync() }
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func memoryCritical() {
        guard let k = kept, !isInUse(k) else { return }
        Log.models.info("critical memory pressure; unloading kept model")
        Task { await unload(k) }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? InferenceClientError {
        case .serviceError(let code) where code == "model_path_rejected": "The model files are in an unexpected place."
        case .serviceError: "The model could not be loaded. Try removing and downloading it again."
        case .connectionFailed: "The inference service didn't respond."
        default: "The model could not be loaded."
        }
    }
}
