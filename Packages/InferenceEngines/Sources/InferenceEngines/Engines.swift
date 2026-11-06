// Parakeet (MLXAudioSTT) and Qwen (MLXLLM) adapters. Linked only by the InferenceService XPC process.
// Models are always loaded from a verified local directory: never `fromPretrained` / hub lookups (§14.1, §15.2).

import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXLLM
import MLXLMCommon
import Tokenizers

public enum EngineError: Error, CustomStringConvertible {
    case modelDirectoryMissing(String)
    case notLoaded
    case cancelled
    case invalidAudio

    public var description: String {
        switch self {
        case .modelDirectoryMissing: "model_directory_missing"
        case .notLoaded: "model_not_loaded"
        case .cancelled: "cancelled"
        case .invalidAudio: "invalid_audio"
        }
    }
}

public struct EngineSegment: Sendable {
    public var text: String
    public var startSeconds: Double
    public var endSeconds: Double
}

public struct EngineTranscription: Sendable {
    public var text: String
    public var segments: [EngineSegment]
    public var elapsedSeconds: Double
}

/// Owns at most one loaded speech model. Not thread-safe by itself; callers serialize through `InferenceScheduler`.
public final class ParakeetEngine: @unchecked Sendable {
    private var model: ParakeetModel?
    public private(set) var loadedDirectory: URL?

    public init() {}

    public var isLoaded: Bool { model != nil }

    public func load(directory: URL) throws -> Double {
        let start = Date()
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            throw EngineError.modelDirectoryMissing(directory.lastPathComponent)
        }
        model = try ParakeetModel.fromDirectory(directory)
        loadedDirectory = directory
        return Date().timeIntervalSince(start)
    }

    /// Transcribes one bounded chunk of 16 kHz mono Float32 PCM held in memory. The app owns chunking,
    /// so the library's internal re-chunking is disabled by using a chunk duration larger than any app chunk.
    public func transcribe(samples: [Float], sampleRate: Int) throws -> EngineTranscription {
        guard let model else { throw EngineError.notLoaded }
        guard !samples.isEmpty, sampleRate == 16_000 else { throw EngineError.invalidAudio }
        let start = Date()
        let audio = MLXArray(samples)
        let params = STTGenerateParameters(
            maxTokens: 4096, temperature: 0, topP: 1, topK: 0, verbose: false,
            language: "en", chunkDuration: 1200, minChunkDuration: 0.1)
        let output = model.generate(audio: audio, generationParameters: params)
        var segments: [EngineSegment] = []
        for raw in output.segments ?? [] {
            let text = (raw["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            let s = (raw["start"] as? Double) ?? Double((raw["start"] as? Float) ?? 0)
            let e = (raw["end"] as? Double) ?? Double((raw["end"] as? Float) ?? Float(s))
            segments.append(EngineSegment(text: text, startSeconds: s, endSeconds: max(e, s)))
        }
        MLX.GPU.clearCache()
        return EngineTranscription(
            text: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments,
            elapsedSeconds: Date().timeIntervalSince(start))
    }

    public func unload() {
        model = nil
        loadedDirectory = nil
        MLX.GPU.clearCache()
    }
}

/// Bridges swift-transformers' tokenizer into MLXLMCommon's protocol (equivalent of the MLXHuggingFace macro,
/// written out so we do not need the swift-syntax macro build or the hub client).
struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream: upstream)
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

public struct LLMGeneration: Sendable {
    public var text: String
    public var promptTokens: Int
    public var generatedTokens: Int
    public var elapsedSeconds: Double
}

/// Owns at most one loaded summary model.
public final class QwenEngine: @unchecked Sendable {
    private var container: ModelContainer?
    public private(set) var loadedDirectory: URL?

    public init() {}

    public var isLoaded: Bool { container != nil }

    public func load(directory: URL) async throws -> Double {
        let start = Date()
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            throw EngineError.modelDirectoryMissing(directory.lastPathComponent)
        }
        // Keep MLX's buffer cache bounded so an idle-but-loaded model does not hoard memory.
        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
        container = try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
        loadedDirectory = directory
        return Date().timeIntervalSince(start)
    }

    public func countTokens(_ text: String) async throws -> Int {
        guard let container else { throw EngineError.notLoaded }
        return await container.perform { ctx in ctx.tokenizer.encode(text: text).count }
    }

    /// Runs one chat completion with a bounded token budget. `isCancelled` is polled between tokens.
    public func generate(
        system: String, user: String, maxTokens: Int, maxKVSize: Int,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> LLMGeneration {
        guard let container else { throw EngineError.notLoaded }
        let start = Date()
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ]
        let promptTokens: [Int] = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(messages: messages)
        }
        var params = MLXLMCommon.GenerateParameters(maxTokens: maxTokens, maxKVSize: maxKVSize, temperature: 0.2, topP: 0.9)
        params.repetitionPenalty = 1.05
        let input = MLXLMCommon.LMInput(tokens: MLXArray(promptTokens))
        let stream = try await container.generate(input: input, parameters: params)
        var text = ""
        var generated = 0
        for await event in stream {
            if isCancelled() { throw EngineError.cancelled }
            switch event {
            case .chunk(let s):
                text += s
            case .info(let info):
                generated = info.generationTokenCount
            default:
                break
            }
        }
        MLX.GPU.clearCache()
        return LLMGeneration(
            text: text, promptTokens: promptTokens.count, generatedTokens: generated,
            elapsedSeconds: Date().timeIntervalSince(start))
    }

    public func unload() {
        container = nil
        loadedDirectory = nil
        MLX.GPU.clearCache()
    }
}

/// Cheap MLX op used by the "ping" path to prove Metal resources are bundled in the service (§A2).
public enum MLXProbe {
    public static func run() -> String {
        let a = MLXArray([1, 2, 3] as [Float])
        let b = (a * 2).sum()
        eval(b)
        return "mlx_ok:\(b.item(Float.self))"
    }

    public static func activeMemoryBytes() -> Int { MLX.GPU.activeMemory }
    public static func peakMemoryBytes() -> Int { MLX.GPU.peakMemory }
}
