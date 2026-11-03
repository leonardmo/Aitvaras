import Accelerate
import Foundation
import AitvarasCore
import AitvarasStore

/// Hybrid retrieval (D11): brute-force cosine over the embedded chunks fused
/// with BM25 keyword hits via reciprocal rank fusion. Either arm degrades
/// gracefully — an unreachable embedder or an all-punctuation query just
/// drops that arm.
public struct HybridRetriever: ContextRetriever {
    private let stores: Stores
    private let embedder: any EmbeddingEngine
    private let sourcesByID: [String: IndexSource]
    private let enforceSourceScope: Bool

    private static let armLimit = 20
    private static let rrfK = 60.0

    /// Compatibility callers can omit scope enforcement. The application
    /// enables it so removed, unavailable, or escaped sources stay excluded.
    public init(stores: Stores, embedder: any EmbeddingEngine, sources: [IndexSource] = [],
                enforceSourceScope: Bool = false) {
        self.stores = stores
        self.embedder = embedder
        self.sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.enforceSourceScope = enforceSourceScope
    }

    public func retrieve(query: String, limit: Int) async throws -> [RetrievedChunk] {
        guard limit > 0 else { return [] }
        try Task.checkCancellation()
        let documents = try stores.allDocuments()
        let eligibleIDs: Set<UUID>? = enforceSourceScope
            ? Set(documents.filter { documentIsEligible($0) }.map(\.id)) : nil
        let vectorRanked = try await vectorArm(query, eligibleDocumentIDs: eligibleIDs)
        // bm25 scores are lower-is-better; keywordSearch already orders ascending.
        let keywordRanked: [UUID]
        if query.contains(where: { $0.isLetter || $0.isNumber }) {
            if let eligibleIDs {
                keywordRanked = try stores.keywordSearch(query, limit: Self.armLimit,
                                                        eligibleDocumentIDs: eligibleIDs).map(\.chunkID)
            } else {
                keywordRanked = try stores.keywordSearch(query, limit: Self.armLimit).map(\.chunkID)
            }
        } else { keywordRanked = [] }

        var fused: [UUID: Double] = [:]
        for (rank, id) in vectorRanked.enumerated() {
            fused[id, default: 0] += 1 / (Self.rrfK + Double(rank + 1))
        }
        for (rank, id) in keywordRanked.enumerated() {
            fused[id, default: 0] += 1 / (Self.rrfK + Double(rank + 1))
        }

        let ranked = fused.sorted { $0.value > $1.value }.prefix(max(0, limit))
        guard !ranked.isEmpty else { return [] }

        let chunksByID = Dictionary(uniqueKeysWithValues: try stores.chunks(ids: ranked.map(\.key)).map { ($0.id, $0) })
        let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        return ranked.compactMap { id, score in
            guard let chunk = chunksByID[id] else { return nil }
            if enforceSourceScope {
                guard let document = documentsByID[chunk.documentID], documentIsEligible(document) else { return nil }
            }
            return RetrievedChunk(text: chunk.text,
                                  origin: origin(of: chunk, in: documentsByID),
                                  score: score)
        }
    }

    private func vectorArm(_ query: String, eligibleDocumentIDs: Set<UUID>?) async throws -> [UUID] {
        let chunks = try eligibleDocumentIDs.map { try stores.chunksWithEmbeddings(eligibleDocumentIDs: $0) }
            ?? stores.chunksWithEmbeddings()
        guard !chunks.isEmpty else { return [] }
        let queryVector: [Float]
        do {
            guard let vector = try await embedder.embed(texts: [query]).first else { return [] }
            try Task.checkCancellation()
            queryVector = vector
        } catch is CancellationError { throw CancellationError() }
        catch { return [] }
        let scored: [(UUID, Float)] = chunks.compactMap { chunk in
            guard let vector = chunk.embeddingVector, vector.count == queryVector.count else { return nil }
            return (chunk.id, Self.cosine(queryVector, vector))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(Self.armLimit).map(\.0)
    }

    private func documentIsEligible(_ document: RAGDocument) -> Bool {
        guard let source = sourcesByID[document.source] else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let root = source.url.resolvingSymlinksInPath().standardizedFileURL.path
        let path = URL(fileURLWithPath: document.path).resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denominator = (normA * normB).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    /// "Notes/ML/lecture-07.md § Backprop" — source name plus the
    /// path relative to the source root, falling back to the file name when
    /// the root is unknown.
    private func origin(of chunk: RAGChunk, in documents: [UUID: RAGDocument]) -> String {
        var location = "unknown"
        if let doc = documents[chunk.documentID] {
            // Indexer stores symlink-resolved paths; resolve the root the same way.
            if let source = sourcesByID[doc.source],
               case let root = source.url.resolvingSymlinksInPath().path,
               doc.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
                let relative = doc.path.dropFirst(root.count).drop(while: { $0 == "/" })
                location = "\(source.name)/\(relative)"
            } else {
                let label = sourcesByID[doc.source]?.name ?? doc.source
                location = "\(label)/\(URL(fileURLWithPath: doc.path).lastPathComponent)"
            }
        }
        if let context = chunk.context, !context.isEmpty {
            location += " § \(context)"
        }
        return location
    }
}
