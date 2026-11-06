import Testing
import Foundation
@testable import InferenceProtocol

@Test func generateRequestBounds() {
    #expect(GenerateRequest(jobID: UUID(), system: "s", user: "u", maxTokens: 100, maxKVSize: 8192).isWithinBounds)
    #expect(!GenerateRequest(jobID: UUID(), system: "s", user: String(repeating: "x", count: 600_000), maxTokens: 100, maxKVSize: 8192).isWithinBounds)
    #expect(!GenerateRequest(jobID: UUID(), system: "s", user: "u", maxTokens: 100_000, maxKVSize: 8192).isWithinBounds)
}

@Test func envelopeRoundTrip() {
    let p = PingResponse(protocolVersion: 1, serviceVersion: "1", mlxProbe: nil, loadedModels: [], activeMemoryBytes: 0, peakMemoryBytes: 0, processID: 1)
    #expect(Wire.decode(PingResponse.self, Wire.encode(p))?.protocolVersion == 1)
    #expect(Wire.decode(PingResponse.self, Data("garbage".utf8)) == nil)
}
