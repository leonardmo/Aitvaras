import Foundation
import AitvarasCore
import AitvarasStore

/// Scripted inference engine shared by agent-layer tests: returns canned
/// text per call in order; a `Self.throwMarker` response throws instead
/// (simulates a dying engine). Records call count.
actor ScriptedEngine: InferenceEngine {
    static let throwMarker = "<<THROW>>"

    let identifier = "scripted"
    private var responses: [String]
    private(set) var calls = 0

    init(responses: [String]) {
        self.responses = responses
    }

    func isAvailable(for tier: ModelTier) async -> Bool { true }

    func callCount() -> Int { calls }

    func complete(messages: [ChatMessage], tools: [ToolDefinition], tier: ModelTier)
        -> AsyncThrowingStream<InferenceChunk, Error> {
        calls += 1
        let response = responses.isEmpty ? "" : responses.removeFirst()
        return AsyncThrowingStream { continuation in
            if response == Self.throwMarker {
                struct EngineDown: Error, LocalizedError {
                    var errorDescription: String? { "engine down" }
                }
                continuation.finish(throwing: EngineDown())
                return
            }
            continuation.yield(.text(response))
            continuation.yield(.done(stopReason: .endOfTurn))
            continuation.finish()
        }
    }
}

func inMemoryStores() throws -> Stores {
    Stores(db: try AitvarasDatabase(url: nil))
}
