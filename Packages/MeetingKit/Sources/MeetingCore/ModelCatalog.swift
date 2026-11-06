import Foundation

/// Bundled model manifest (§15.1).
public struct ModelCatalogEntry: Codable, Sendable, Equatable, Identifiable {
    public struct File: Codable, Sendable, Equatable {
        public var relativePath: String
        public var byteCount: Int64
        public var sha256: String
    }

    public enum Purpose: String, Codable, Sendable { case speechToText, summary }

    public var catalogSchemaVersion: Int
    public var id: String
    public var displayName: String
    public var purpose: Purpose
    public var upstreamRepository: String
    public var artifactRepository: String
    public var artifactRevision: String
    public var runtime: String
    public var format: String
    public var languages: [String]
    public var licenseSPDX: String
    public var attribution: String
    public var minimumAppVersion: String
    public var files: [File]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }

    public func downloadURL(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(artifactRepository)/resolve/\(artifactRevision)/\(file.relativePath)")!
    }
}

public struct ModelCatalog: Codable, Sendable, Equatable {
    public var catalogSchemaVersion: Int
    public var models: [ModelCatalogEntry]

    public init(catalogSchemaVersion: Int, models: [ModelCatalogEntry]) {
        self.catalogSchemaVersion = catalogSchemaVersion; self.models = models
    }

    public func entry(_ purpose: ModelCatalogEntry.Purpose) -> ModelCatalogEntry? { models.first { $0.purpose == purpose } }

    /// Shipping-manifest gate used by scripts/verify-manifest and tests (§E1).
    public static func validationErrors(_ catalog: ModelCatalog) -> [String] {
        var errors: [String] = []
        let hex = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        let rev = try! NSRegularExpression(pattern: "^[0-9a-f]{40}$")
        func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
            r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
        for m in catalog.models {
            for (name, value) in [("artifactRevision", m.artifactRevision), ("attribution", m.attribution),
                                  ("minimumAppVersion", m.minimumAppVersion), ("licenseSPDX", m.licenseSPDX)] {
                if value.contains("<") || value.contains(">") || value.isEmpty { errors.append("\(m.id): placeholder \(name)") }
            }
            if !matches(rev, m.artifactRevision) { errors.append("\(m.id): artifactRevision is not an immutable commit") }
            if m.files.isEmpty { errors.append("\(m.id): no files") }
            for f in m.files {
                if f.byteCount <= 0 { errors.append("\(m.id): \(f.relativePath) zero byte count") }
                if !matches(hex, f.sha256) { errors.append("\(m.id): \(f.relativePath) invalid sha256") }
                if f.relativePath.contains("..") || f.relativePath.hasPrefix("/") { errors.append("\(m.id): unsafe path \(f.relativePath)") }
                let ext = (f.relativePath as NSString).pathExtension.lowercased()
                if ["py", "pkl", "pickle", "bin", "pt", "pth", "sh", "dylib", "so", "exe"].contains(ext) {
                    errors.append("\(m.id): unsafe file type \(f.relativePath)")
                }
            }
        }
        return errors
    }
}

public enum ModelInstallState: Sendable, Equatable {
    case absent
    case downloading(received: Int64, total: Int64)
    case paused(received: Int64, total: Int64)
    case verifying
    case ready
    case loading
    case inUse
    case failed(String)
    case incompatible(String)

    public var isReady: Bool {
        switch self { case .ready, .loading, .inUse: true; default: false }
    }

    public var label: String {
        switch self {
        case .absent: "Not installed"
        case .downloading(let r, let t): "Downloading \(ByteCountFormatter.string(fromByteCount: r, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: t, countStyle: .file))"
        case .paused(let r, let t): "Paused at \(ByteCountFormatter.string(fromByteCount: r, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: t, countStyle: .file))"
        case .verifying: "Verifying"
        case .ready: "Ready"
        case .loading: "Loading"
        case .inUse: "In use"
        case .failed(let m): "Failed: \(m)"
        case .incompatible(let m): "Incompatible: \(m)"
        }
    }
}

/// Validates a path inside a model directory: no traversal, no absolute paths (§15.2).
public enum ModelPathPolicy {
    public static func isSafe(relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\") else { return false }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    public static let allowedRedirectHostSuffixes = ["huggingface.co", "hf.co", ".huggingface.co", ".hf.co", ".cloudfront.net", ".xethub.hf.co"]

    public static func isAllowedDownloadHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedRedirectHostSuffixes.contains { s in s.hasPrefix(".") ? host.hasSuffix(s) : host == s }
    }
}
