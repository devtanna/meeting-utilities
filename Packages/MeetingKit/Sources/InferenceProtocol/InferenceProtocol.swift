import Foundation

/// Versioned XPC contract between the host app and the embedded InferenceService (§4.1).
/// All arguments are `Data` (NSSecureCoding-compatible NSData) containing versioned Codable envelopes,
/// plus a raw little-endian Float32 PCM payload for audio chunks. The service has no database access and
/// accepts no arbitrary command or download request.
public enum InferenceProtocolVersion {
    public static let current = 1
    public static let maxPCMBytes = 2 * 1024 * 1024          // 2 MiB per chunk
    public static let maxTextBytes = 512 * 1024              // bounded text payloads
    public static let sampleRate = 16_000
    public static let serviceName = "com.devtanna.meetingutils.InferenceService"
}

@objc public protocol InferenceServiceXPC {
    func ping(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func loadModel(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func unloadModels(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func transcribe(_ header: Data, pcm: Data, reply: @escaping @Sendable (Data) -> Void)
    func generate(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func cancel(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// The text a running `generate` job has written so far, so the app can show it as it is written.
    func generationProgress(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

public enum ModelKind: String, Codable, Sendable { case speech, summary }

public struct PingRequest: Codable, Sendable {
    public var protocolVersion = InferenceProtocolVersion.current
    public var runMLXProbe: Bool
    public init(runMLXProbe: Bool) { self.runMLXProbe = runMLXProbe }
}

public struct PingResponse: Codable, Sendable {
    public var protocolVersion: Int
    public var serviceVersion: String
    public var mlxProbe: String?
    public var loadedModels: [String]
    public var activeMemoryBytes: Int
    public var peakMemoryBytes: Int
    public var processID: Int32
    public init(protocolVersion: Int, serviceVersion: String, mlxProbe: String?, loadedModels: [String],
                activeMemoryBytes: Int, peakMemoryBytes: Int, processID: Int32) {
        self.protocolVersion = protocolVersion; self.serviceVersion = serviceVersion; self.mlxProbe = mlxProbe
        self.loadedModels = loadedModels; self.activeMemoryBytes = activeMemoryBytes; self.peakMemoryBytes = peakMemoryBytes
        self.processID = processID
    }
}

public struct LoadModelRequest: Codable, Sendable {
    public var protocolVersion = InferenceProtocolVersion.current
    public var kind: ModelKind
    public var modelID: String
    public var revision: String
    public var directoryPath: String
    public init(kind: ModelKind, modelID: String, revision: String, directoryPath: String) {
        self.kind = kind; self.modelID = modelID; self.revision = revision; self.directoryPath = directoryPath
    }
}

public struct SimpleResponse: Codable, Sendable {
    public var protocolVersion = InferenceProtocolVersion.current
    public var ok: Bool
    public var errorCode: String?
    public var elapsedSeconds: Double?
    public init(ok: Bool, errorCode: String? = nil, elapsedSeconds: Double? = nil) {
        self.ok = ok; self.errorCode = errorCode; self.elapsedSeconds = elapsedSeconds
    }
}

public enum AudioSourceTag: String, Codable, Sendable { case microphone, system }

public struct ChunkHeader: Codable, Sendable, Equatable {
    public var protocolVersion = InferenceProtocolVersion.current
    public var sessionID: UUID
    public var jobID: UUID
    public var generation: Int
    public var sequence: Int
    public var source: AudioSourceTag
    public var sampleRate: Int
    public var frameCount: Int
    public var hostTimeStartSeconds: Double
    public var hostTimeEndSeconds: Double

    public init(sessionID: UUID, jobID: UUID, generation: Int, sequence: Int, source: AudioSourceTag, sampleRate: Int,
                frameCount: Int, hostTimeStartSeconds: Double, hostTimeEndSeconds: Double) {
        self.sessionID = sessionID; self.jobID = jobID; self.generation = generation; self.sequence = sequence
        self.source = source; self.sampleRate = sampleRate; self.frameCount = frameCount
        self.hostTimeStartSeconds = hostTimeStartSeconds; self.hostTimeEndSeconds = hostTimeEndSeconds
    }

    public enum ValidationError: String, Error, Sendable { case version, size, rate, frames, range, sequence }

    /// Validate sizes and ranges before allocation (§4.1).
    public func validate(pcmByteCount: Int) -> ValidationError? {
        if protocolVersion != InferenceProtocolVersion.current { return .version }
        if pcmByteCount > InferenceProtocolVersion.maxPCMBytes || pcmByteCount <= 0 { return .size }
        if sampleRate != InferenceProtocolVersion.sampleRate { return .rate }
        if frameCount * MemoryLayout<Float>.size != pcmByteCount { return .frames }
        if !(hostTimeEndSeconds >= hostTimeStartSeconds) || !hostTimeStartSeconds.isFinite { return .range }
        if sequence < 0 { return .sequence }
        return nil
    }
}

public struct ChunkSegment: Codable, Sendable, Equatable {
    public var text: String
    public var startSeconds: Double   // relative to chunk start
    public var endSeconds: Double
    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text; self.startSeconds = startSeconds; self.endSeconds = endSeconds
    }
}

public struct ChunkResult: Codable, Sendable {
    public var protocolVersion = InferenceProtocolVersion.current
    public var sessionID: UUID
    public var generation: Int
    public var sequence: Int
    public var source: AudioSourceTag
    public var ok: Bool
    public var errorCode: String?
    public var text: String
    public var segments: [ChunkSegment]
    public var computeSeconds: Double
    public init(sessionID: UUID, generation: Int, sequence: Int, source: AudioSourceTag, ok: Bool, errorCode: String?,
                text: String, segments: [ChunkSegment], computeSeconds: Double) {
        self.sessionID = sessionID; self.generation = generation; self.sequence = sequence; self.source = source
        self.ok = ok; self.errorCode = errorCode; self.text = text; self.segments = segments; self.computeSeconds = computeSeconds
    }
}

public struct GenerateRequest: Codable, Sendable {
    public var protocolVersion = InferenceProtocolVersion.current
    public var jobID: UUID
    public var system: String
    public var user: String
    public var maxTokens: Int
    public var maxKVSize: Int
    public init(jobID: UUID, system: String, user: String, maxTokens: Int, maxKVSize: Int) {
        self.jobID = jobID; self.system = system; self.user = user; self.maxTokens = maxTokens; self.maxKVSize = maxKVSize
    }

    public var isWithinBounds: Bool {
        system.utf8.count + user.utf8.count <= InferenceProtocolVersion.maxTextBytes && maxTokens > 0 && maxTokens <= 4096
            && maxKVSize > 0 && maxKVSize <= 32768
    }
}

public struct GenerateResult: Codable, Sendable {
    public var protocolVersion = InferenceProtocolVersion.current
    public var jobID: UUID
    public var ok: Bool
    public var errorCode: String?
    public var text: String
    public var promptTokens: Int
    public var generatedTokens: Int
    public var elapsedSeconds: Double
    public init(jobID: UUID, ok: Bool, errorCode: String?, text: String, promptTokens: Int, generatedTokens: Int, elapsedSeconds: Double) {
        self.jobID = jobID; self.ok = ok; self.errorCode = errorCode; self.text = text; self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens; self.elapsedSeconds = elapsedSeconds
    }
}

public struct GenerationProgressRequest: Codable, Sendable {
    public var protocolVersion = InferenceProtocolVersion.current
    public var jobID: UUID
    public init(jobID: UUID) { self.jobID = jobID }
}

public struct GenerationProgress: Codable, Sendable {
    public var protocolVersion = InferenceProtocolVersion.current
    public var jobID: UUID
    /// False when the service has no running generation for this job.
    public var running: Bool
    public var text: String
    public var generatedTokens: Int
    public init(jobID: UUID, running: Bool, text: String, generatedTokens: Int) {
        self.jobID = jobID; self.running = running; self.text = text; self.generatedTokens = generatedTokens
    }
}

public struct CancelRequest: Codable, Sendable {
    public var protocolVersion = InferenceProtocolVersion.current
    public var jobID: UUID?
    public var sessionID: UUID?
    public init(jobID: UUID?, sessionID: UUID?) { self.jobID = jobID; self.sessionID = sessionID }
}

public enum Wire {
    public static func encode<T: Encodable>(_ v: T) -> Data { (try? JSONEncoder().encode(v)) ?? Data() }
    public static func decode<T: Decodable>(_ t: T.Type, _ d: Data) -> T? {
        guard d.count <= InferenceProtocolVersion.maxTextBytes * 2 else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }

    public static func pcmData(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func samples(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
