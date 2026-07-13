import Foundation

/// What RAG returns into the agent loop (implemented in AitvarasRAG).
public struct RetrievedChunk: Sendable, Equatable {
    public var text: String
    /// Human-readable origin, e.g. "Notes/ML/lecture-07.md § Backprop"
    public var origin: String
    public var score: Double

    public init(text: String, origin: String, score: Double) {
        self.text = text
        self.origin = origin
        self.score = score
    }
}

public protocol ContextRetriever: Sendable {
    func retrieve(query: String, limit: Int) async throws -> [RetrievedChunk]
}
