import Accelerate
import Foundation
import AitvarasCore
import AitvarasStore

/// Hybrid recall over the fact store (MASTERPLAN §9 "Retrieval"): the vector
/// arm (brute-force cosine over embedded facts) and the keyword arm (BM25 over
/// FTS5) are reciprocal-rank-fused, then nudged by an importance × recency
/// prior so relevance leads but stable, salient facts break ties. Either arm
/// degrades gracefully — an unreachable embedder drops the vector arm, an
/// all-punctuation query drops the keyword arm.
///
/// Kept separate from the doc-RAG `HybridRetriever` on purpose: this searches
/// currently-valid facts by default and applies memory-specific scoring; the
/// two are distinct tool namespaces (`memory_search` ≠ `knowledge_search`, O11).
struct MemoryRecall {
    private let stores: Stores
    private let embedder: any EmbeddingEngine

    private static let armLimit = 20
    private static let rrfK = 60.0
    /// Small enough that relevance dominates; large enough to order near-ties.
    private static let importanceWeight = 0.004
    private static let recencyWeight = 0.003
    private static let recencyHalfLife: TimeInterval = 30 * 24 * 3600   // 30 days

    init(stores: Stores, embedder: any EmbeddingEngine) {
        self.stores = stores
        self.embedder = embedder
    }

    /// Recall the most relevant currently-valid facts and bump their recency.
    func recall(query: String, limit: Int, now: Date = .now) async -> [MemoryFact] {
        let vectorRanked = await vectorArm(query)
        let keywordRanked = ((try? stores.factKeywordSearch(query, limit: Self.armLimit)) ?? []).map(\.factID)

        var fused: [UUID: Double] = [:]
        for (rank, id) in vectorRanked.enumerated() {
            fused[id, default: 0] += 1 / (Self.rrfK + Double(rank + 1))
        }
        for (rank, id) in keywordRanked.enumerated() {
            fused[id, default: 0] += 1 / (Self.rrfK + Double(rank + 1))
        }
        guard !fused.isEmpty else { return [] }

        let factsByID = Dictionary(
            uniqueKeysWithValues: (try? stores.facts(ids: Array(fused.keys)))?
                .filter { $0.isCurrentlyValid && !$0.needsReview }.map { ($0.id, $0) } ?? [])

        let scored = fused.compactMap { id, rrf -> (MemoryFact, Double)? in
            guard let fact = factsByID[id] else { return nil }
            let importancePrior = Double(fact.importance) * Self.importanceWeight
            let ageDays = max(0, now.timeIntervalSince(fact.lastAccessed)) / Self.recencyHalfLife
            let recencyPrior = pow(0.5, ageDays) * Self.recencyWeight
            return (fact, rrf + importancePrior + recencyPrior)
        }

        let ranked = scored.sorted { $0.1 > $1.1 }.prefix(max(0, limit)).map(\.0)
        try? stores.touchFacts(ids: ranked.map(\.id), at: now)
        return ranked
    }

    private func vectorArm(_ query: String) async -> [UUID] {
        guard let queryVector = try? await embedder.embed(texts: [query]).first,
              let facts = try? stores.factsWithEmbeddings(activeOnly: true), !facts.isEmpty
        else { return [] }
        let scored: [(UUID, Float)] = facts.compactMap { fact in
            guard let vector = fact.embeddingVector, vector.count == queryVector.count else { return nil }
            return (fact.id, Self.cosine(queryVector, vector))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(Self.armLimit).map(\.0)
    }

    /// Best-effort embedding for a fact being written; nil on embedder failure
    /// (the fact is still stored and FTS-searchable, and a later pass can fill it).
    func embedding(for text: String) async -> Data? {
        guard let vector = try? await embedder.embed(texts: [text]).first else { return nil }
        return vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denominator = (normA * normB).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }
}
