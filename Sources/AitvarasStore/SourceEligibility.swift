import Foundation
import GRDB

extension Stores {
    public func chunksWithEmbeddings(eligibleDocumentIDs: Set<UUID>) throws -> [RAGChunk] {
        guard !eligibleDocumentIDs.isEmpty else { return [] }
        return try db.queue.read {
            try RAGChunk.filter(eligibleDocumentIDs.contains(Column("documentID")))
                .filter(Column("embedding") != nil).fetchAll($0)
        }
    }

    /// Restrict eligibility before ordering and the arm limit, not after it.
    /// One JSON parameter avoids SQLite's per-statement bind-variable limit
    /// when a selected source has many thousands of chunks.
    public func keywordSearch(_ query: String, limit: Int,
                              eligibleDocumentIDs: Set<UUID>) throws -> [(chunkID: UUID, score: Double)] {
        guard limit > 0, !eligibleDocumentIDs.isEmpty else { return [] }
        return try db.queue.read { dbc in
            let eligible = Set(try UUID.fetchAll(dbc, RAGChunk
                .filter(eligibleDocumentIDs.contains(Column("documentID"))).select(Column("id"))))
            let identifiers = String(decoding: try JSONEncoder().encode(eligible.map(\.uuidString)), as: UTF8.self)
            let rows = try Row.fetchAll(dbc, sql: """
                SELECT chunkID, bm25(ragFTS) AS score FROM ragFTS
                WHERE ragFTS MATCH ? AND chunkID IN (SELECT value FROM json_each(?))
                ORDER BY score LIMIT ?
                """, arguments: [Self.ftsQuery(query), identifiers, limit])
            return rows.compactMap { row -> (chunkID: UUID, score: Double)? in
                guard let id = UUID(uuidString: row["chunkID"]) else { return nil }
                return (id, row["score"] as Double? ?? 0)
            }
        }
    }
}
