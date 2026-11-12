import CryptoKit
import Foundation
import MeetingCore

/// Explicit, verified, resumable model downloads (§15). Weights are never fetched implicitly.
@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var states: [String: ModelInstallState] = [:]
    let catalog: ModelCatalog
    let root: URL
    private var downloads: [String: ModelDownload] = [:]
    var isInUse: (String) -> Bool = { _ in false }
    var onDeleted: ((String) -> Void)?

    init(appSupport: URL) {
        root = appSupport
        let url = Bundle.main.url(forResource: "ModelCatalog", withExtension: "json")
        catalog = (url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(ModelCatalog.self, from: $0) })
            ?? ModelCatalog(catalogSchemaVersion: 1, models: [])
        for m in catalog.models { states[m.id] = computeState(m) }
    }

    var modelsDir: URL { root.appendingPathComponent("Models", isDirectory: true) }
    var stagingDir: URL { root.appendingPathComponent("ModelStaging", isDirectory: true) }

    func installDirectory(_ m: ModelCatalogEntry) -> URL {
        modelsDir.appendingPathComponent(m.id, isDirectory: true).appendingPathComponent(m.artifactRevision, isDirectory: true)
    }
    func stagingDirectory(_ m: ModelCatalogEntry) -> URL { stagingDir.appendingPathComponent("\(m.id)-\(m.artifactRevision)", isDirectory: true) }

    func entry(_ purpose: ModelCatalogEntry.Purpose) -> ModelCatalogEntry? { catalog.entry(purpose) }
    func state(_ purpose: ModelCatalogEntry.Purpose) -> ModelInstallState { entry(purpose).flatMap { states[$0.id] } ?? .absent }
    func isReady(_ purpose: ModelCatalogEntry.Purpose) -> Bool { state(purpose).isReady }

    /// Installed means a verified marker exists — never just "file exists" (§15.2).
    private func computeState(_ m: ModelCatalogEntry) -> ModelInstallState {
        let marker = installDirectory(m).appendingPathComponent(".verified.json")
        if FileManager.default.fileExists(atPath: marker.path) { return .ready }
        let staged = stagedBytes(m)
        if staged > 0 { return .paused(received: staged, total: m.totalBytes) }
        return .absent
    }

    func stagedBytes(_ m: ModelCatalogEntry) -> Int64 {
        m.files.reduce(0) { acc, f in
            let size = (try? FileManager.default.attributesOfItem(atPath: stagingDirectory(m).appendingPathComponent(f.relativePath).path)[.size] as? Int64) ?? 0
            return acc + min(size ?? 0, f.byteCount)
        }
    }

    var freeSpaceBytes: Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func diskUse(_ m: ModelCatalogEntry) -> Int64 {
        guard let e = FileManager.default.enumerator(at: installDirectory(m), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    func startDownload(_ m: ModelCatalogEntry) {
        guard downloads[m.id] == nil else { return }
        guard freeSpaceBytes > m.totalBytes - stagedBytes(m) + 512 * 1024 * 1024 else {
            states[m.id] = .failed("Not enough free space"); return
        }
        let d = ModelDownload(entry: m, staging: stagingDirectory(m))
        downloads[m.id] = d
        states[m.id] = .downloading(received: stagedBytes(m), total: m.totalBytes)
        d.onProgress = { [weak self] received in
            Task { @MainActor in
                guard let self, case .downloading = self.states[m.id] else { return }
                self.states[m.id] = .downloading(received: received, total: m.totalBytes)
            }
        }
        d.onFinished = { [weak self] error in
            Task { @MainActor in self?.finished(m, error: error) }
        }
        Log.models.info("download start model=\(m.id, privacy: .public)")
        d.start()
    }

    func pause(_ m: ModelCatalogEntry) {
        downloads[m.id]?.cancel()
        downloads[m.id] = nil
        states[m.id] = .paused(received: stagedBytes(m), total: m.totalBytes)
    }

    func cancelDownload(_ m: ModelCatalogEntry) {
        downloads[m.id]?.cancel()
        downloads[m.id] = nil
        try? FileManager.default.removeItem(at: stagingDirectory(m))
        states[m.id] = .absent
    }

    private func finished(_ m: ModelCatalogEntry, error: String?) {
        downloads[m.id] = nil
        if let error {
            if case .paused = states[m.id] { return }
            states[m.id] = .failed(error); return
        }
        states[m.id] = .verifying
        let staging = stagingDirectory(m), dest = installDirectory(m)
        Task.detached(priority: .utility) {
            let result = Self.verifyAndInstall(m, staging: staging, dest: dest)
            await MainActor.run {
                self.states[m.id] = result == nil ? .ready : .failed(result!)
                Log.models.info("install model=\(m.id, privacy: .public) ok=\(result == nil, privacy: .public)")
            }
        }
    }

    /// Exact size + SHA-256 for every file, no symlinks, no unexpected files, atomic move (§15.2).
    nonisolated static func verifyAndInstall(_ m: ModelCatalogEntry, staging: URL, dest: URL) -> String? {
        let fm = FileManager.default
        for f in m.files {
            guard ModelPathPolicy.isSafe(relativePath: f.relativePath) else { return "Unsafe path" }
            let u = staging.appendingPathComponent(f.relativePath)
            guard let attrs = try? fm.attributesOfItem(atPath: u.path), attrs[.type] as? FileAttributeType == .typeRegular else { return "Missing or non-regular file" }
            guard (attrs[.size] as? Int64) == f.byteCount else {
                try? fm.removeItem(at: u)
                return "Wrong size for \(f.relativePath)"
            }
            guard sha256(u) == f.sha256 else {
                try? fm.removeItem(at: u)
                return "Checksum mismatch for \(f.relativePath)"
            }
        }
        let expected = Set(m.files.map(\.relativePath) + [".state.json"])
        for name in (try? fm.contentsOfDirectory(atPath: staging.path)) ?? [] where !expected.contains(name) {
            try? fm.removeItem(at: staging.appendingPathComponent(name))
        }
        try? fm.removeItem(at: staging.appendingPathComponent(".state.json"))
        let marker = try? JSONEncoder().encode(["id": m.id, "revision": m.artifactRevision, "verifiedAt": ISO8601DateFormatter().string(from: Date())])
        fm.createFile(atPath: staging.appendingPathComponent(".verified.json").path, contents: marker)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: staging, to: dest) // same volume → atomic rename
        } catch {
            return "Install failed"
        }
        return nil
    }

    nonisolated static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        // Drain each 8 MB read immediately; without the pool, autoreleased buffers accumulate to the file size.
        while true {
            let done: Bool = autoreleasepool {
                guard let chunk = try? h.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty else { return true }
                hasher.update(data: chunk)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum DeleteOutcome { case deleted, inUse }

    /// Deleting weights never deletes notes, transcripts, or summaries (§15.3).
    func delete(_ m: ModelCatalogEntry, force: Bool = false) -> DeleteOutcome {
        if isInUse(m.id) && !force { return .inUse }
        downloads[m.id]?.cancel(); downloads[m.id] = nil
        try? FileManager.default.removeItem(at: modelsDir.appendingPathComponent(m.id))
        try? FileManager.default.removeItem(at: stagingDirectory(m))
        states[m.id] = .absent
        onDeleted?(m.id)
        return .deleted
    }

    func setInUse(_ purpose: ModelCatalogEntry.Purpose, _ inUse: Bool) {
        guard let m = entry(purpose), states[m.id]?.isReady == true else { return }
        states[m.id] = inUse ? .inUse : .ready
    }
}

/// Downloads one model's files with at most two concurrent requests, Range/ETag resume, and redirect host checks.
final class ModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct FileState: Codable { var etag: String? }

    let entry: ModelCatalogEntry
    let staging: URL
    var onProgress: ((Int64) -> Void)?
    var onFinished: ((String?) -> Void)?
    private var session: URLSession!
    private let lock = NSLock()
    private var queue: [ModelCatalogEntry.File] = []
    private var active: [Int: (file: ModelCatalogEntry.File, handle: FileHandle, offset: Int64)] = [:]
    private var etags: [String: String] = [:]
    private var receivedBase: Int64 = 0
    private var receivedLive: [Int: Int64] = [:]
    private var failed: String?
    private var cancelled = false
    private var reported = false
    private var lastReport = Date.distantPast

    init(entry: ModelCatalogEntry, staging: URL) {
        self.entry = entry
        self.staging = staging
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["User-Agent": "MeetingUtility-ModelDownloader/1"]
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: q)
    }

    private var statePath: URL { staging.appendingPathComponent(".state.json") }

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let d = try? Data(contentsOf: statePath), let s = try? JSONDecoder().decode([String: FileState].self, from: d) {
            etags = s.compactMapValues(\.etag)
        }
        lock.withLock {
            for f in entry.files {
                let size = (try? fm.attributesOfItem(atPath: staging.appendingPathComponent(f.relativePath).path)[.size] as? Int64) ?? 0
                if (size ?? 0) == f.byteCount { receivedBase += f.byteCount } else { queue.append(f) }
            }
        }
        pump()
    }

    func cancel() {
        lock.withLock { cancelled = true }
        session.invalidateAndCancel()
    }

    private func pump() {
        lock.lock()
        if cancelled || reported { lock.unlock(); return }
        if let failed {
            reported = true
            lock.unlock()
            session.invalidateAndCancel()
            onFinished?(failed)
            return
        }
        if queue.isEmpty && active.isEmpty {
            reported = true
            lock.unlock()
            session.finishTasksAndInvalidate()
            onFinished?(nil)
            return
        }
        while active.count < 2, !queue.isEmpty {
            let f = queue.removeFirst()
            guard ModelPathPolicy.isSafe(relativePath: f.relativePath) else { failed = "Unsafe path"; break }
            let url = staging.appendingPathComponent(f.relativePath)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let h = try? FileHandle(forWritingTo: url) else { failed = "Cannot write staging file"; break }
            let offset = (try? h.seekToEnd()).map(Int64.init) ?? 0
            var req = URLRequest(url: entry.downloadURL(for: f))
            if offset > 0 {
                req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                if let etag = etags[f.relativePath] { req.setValue(etag, forHTTPHeaderField: "If-Range") }
            }
            let task = session.dataTask(with: req)
            active[task.taskIdentifier] = (f, h, offset)
            receivedLive[task.taskIdentifier] = offset
            task.resume()
        }
        let err = failed
        if err != nil { reported = true }
        lock.unlock()
        if let err { session.invalidateAndCancel(); onFinished?(err) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        // Only HTTPS redirects to the expected artifact/CDN hosts (§15.2).
        guard let u = request.url, ModelPathPolicy.isAllowedDownloadHost(u) else { return nil }
        return request
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        let disposition: URLSession.ResponseDisposition = lock.withLock {
            guard var entry = active[dataTask.taskIdentifier] else { return .cancel }
            if let etag = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "X-Linked-Etag") { etags[entry.file.relativePath] = etag; persistState() }
            switch http.statusCode {
            case 206: return .allow
            case 200:
                // Server ignored the range or the remote object changed: restart this file from zero.
                try? entry.handle.truncate(atOffset: 0)
                entry.offset = 0
                active[dataTask.taskIdentifier] = entry
                receivedLive[dataTask.taskIdentifier] = 0
                return .allow
            default:
                failed = "HTTP \(http.statusCode)"
                return .cancel
            }
        }
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let entry = active[dataTask.taskIdentifier] else { lock.unlock(); return }
        try? entry.handle.write(contentsOf: data)
        receivedLive[dataTask.taskIdentifier, default: 0] += Int64(data.count)
        if receivedLive[dataTask.taskIdentifier]! > entry.file.byteCount { failed = "Unexpected size"; lock.unlock(); dataTask.cancel(); return }
        let total = receivedBase + receivedLive.values.reduce(0, +)
        let report = Date().timeIntervalSince(lastReport) > 0.25
        if report { lastReport = Date() }
        lock.unlock()
        if report { onProgress?(total) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = active.removeValue(forKey: task.taskIdentifier)
        try? entry?.handle.close()
        if let entry {
            let live = receivedLive.removeValue(forKey: task.taskIdentifier) ?? 0
            if error == nil && failed == nil && live == entry.file.byteCount { receivedBase += entry.file.byteCount }
            else if error != nil && !cancelled && failed == nil { failed = "Network error" }
            else if error == nil && failed == nil && live != entry.file.byteCount { failed = "Incomplete file" }
        }
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { return }
        pump()
    }

    private func persistState() {
        let s = etags.mapValues { FileState(etag: $0) }
        try? JSONEncoder().encode(s).write(to: statePath)
    }
}
