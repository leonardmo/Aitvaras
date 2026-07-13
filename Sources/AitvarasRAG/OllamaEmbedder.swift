import Foundation
import AitvarasCore

public enum RAGError: Error, Sendable {
    case embedderUnavailable(status: Int)
    case embeddingCountMismatch(expected: Int, got: Int)
}

/// Stopgap embedding engine (D11): nomic-embed-text via the local Ollama
/// daemon. Swappable for an MLX-hosted multilingual model (Qwen3-Embedding,
/// bge-m3) behind the same `EmbeddingEngine` protocol.
public actor OllamaEmbedder: EmbeddingEngine {
    public let identifier: String
    public let dimensions = 768

    private let baseURL: URL
    private let model: String
    private let session: URLSession

    private static let batchSize = 16

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                model: String = "nomic-embed-text") {
        self.baseURL = baseURL
        self.model = model
        self.identifier = "ollama-embed/\(model)"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
    }

    public func embed(texts: [String]) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        var index = 0
        while index < texts.count {
            let batch = Array(texts[index..<min(index + Self.batchSize, texts.count)])
            vectors.append(contentsOf: try await embedBatch(batch))
            index += Self.batchSize
        }
        return vectors
    }

    private struct EmbedRequest: Encodable {
        let model: String
        let input: [String]
    }

    private struct EmbedResponse: Decodable {
        let embeddings: [[Float]]
    }

    private func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(EmbedRequest(model: model, input: texts))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RAGError.embedderUnavailable(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
        guard decoded.embeddings.count == texts.count else {
            throw RAGError.embeddingCountMismatch(expected: texts.count, got: decoded.embeddings.count)
        }
        return decoded.embeddings
    }
}
