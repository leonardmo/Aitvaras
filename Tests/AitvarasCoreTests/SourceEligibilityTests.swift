import Foundation
import Testing
import AitvarasCore
import AitvarasStore
import AitvarasRAG

private actor ScopeEmbedder: EmbeddingEngine {
    let identifier = "synthetic-scope-embedder"
    let dimensions = 2
    private var calls: [[String]] = []
    func embed(texts: [String]) async throws -> [[Float]] {
        calls.append(texts)
        return texts.map { _ in [1, 0] }
    }
    func inputs() -> [String] { calls.flatMap { $0 } }
}

private actor PausedScopeEmbedder: EmbeddingEngine {
    let identifier = "synthetic-paused-embedder"
    let dimensions = 2
    private var started = false
    private var released = false
    func embed(texts: [String]) async throws -> [[Float]] {
        started = true
        // Deliberately ignores cancellation to test the indexer's own write
        // boundary after an uncooperative embedder finishes.
        while !released { await Task.yield() }
        return texts.map { _ in [1, 0] }
    }
    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
    func release() { released = true }
}

@Suite struct SourceEligibilityTests {
    @Test func automaticScanDoesNothingUntilReviewedAndPausedScansStayBlocked() async throws {
        let stores = try inMemoryStores()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "Synthetic indexing fixture".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let embedder = ScopeEmbedder()
        let reporter = ActivityReporter(stores: stores)
        let indexer = Indexer(stores: stores, embedder: embedder, reporter: reporter)
        let sources = [IndexSource(id: "fixture", name: "Fixture", url: root)]
        try await ActivityTaskContext.$trigger.withValue(.automatic) {
            try await indexer.fullScan(sources: sources)
        }
        #expect(try stores.allDocuments().isEmpty)
        #expect(await embedder.inputs().isEmpty)
        #expect(try stores.activityRuns().isEmpty)
        try stores.saveBackgroundWorkPolicy(BackgroundWorkPolicy(reviewed: true, allowed: [.indexing]))
        try await ActivityTaskContext.$trigger.withValue(.automatic) { try await indexer.fullScan(sources: sources) }
        #expect(try stores.allDocuments().count == 1)
        #expect(try stores.activityRuns().count == 1)
        try await ActivityTaskContext.$trigger.withValue(.automatic) { try await indexer.fullScan(sources: sources) }
        #expect(try stores.activityRuns().count == 1) // Unchanged checks do not flood history.
        try stores.saveBackgroundWorkPolicy(BackgroundWorkPolicy(reviewed: true, paused: true, allowed: [.indexing]))
        try "Changed fixture".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try await ActivityTaskContext.$trigger.withValue(.automatic) { try await indexer.fullScan(sources: sources) }
        #expect(try stores.activityRuns().count == 1)
        #expect(await embedder.inputs() == ["Synthetic indexing fixture"])
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("source-scope-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func add(_ stores: Stores, source: String, path: String, text: String,
                     vector: [Float]? = nil) throws {
        let document = RAGDocument(source: source, path: path, mtime: 0, contentHash: "fixture")
        var chunk = RAGChunk(documentID: document.id, ord: 0, text: text)
        chunk.embeddingVector = vector
        try stores.upsertDocument(document, chunks: [chunk])
    }

    @Test func strictScopeExcludesUnregisteredAndMissingSourcesWithoutDeletingData() async throws {
        let stores = try inMemoryStores()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = IndexSource(id: "allowed", name: "Allowed", url: root)
        try add(stores, source: source.id, path: root.appendingPathComponent("good.txt").path,
                text: "target allowed", vector: [1, 0])
        try add(stores, source: "removed", path: root.appendingPathComponent("removed.txt").path,
                text: "target removed", vector: [1, 0])
        let missing = root.appendingPathComponent("missing")
        try add(stores, source: "missing", path: missing.appendingPathComponent("old.txt").path,
                text: "target unavailable", vector: [1, 0])
        let embedder = ScopeEmbedder()
        let strict = HybridRetriever(stores: stores, embedder: embedder, sources: [source,
            IndexSource(id: "missing", name: "Missing", url: missing)], enforceSourceScope: true)
        #expect(try await strict.retrieve(query: "target", limit: 10).map(\.text) == ["target allowed"])
        #expect(try stores.allDocuments().count == 3)
        let compatibility = HybridRetriever(stores: stores, embedder: embedder)
        #expect(try await compatibility.retrieve(query: "target", limit: 10).count == 3)
        let empty = HybridRetriever(stores: stores, embedder: embedder, enforceSourceScope: true)
        #expect(try await empty.retrieve(query: "target", limit: 10).isEmpty)
    }

    @Test func canonicalBoundaryRejectsSiblingPrefixAndSymlinkEscape() async throws {
        let stores = try inMemoryStores()
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("notes")
        let sibling = base.appendingPathComponent("notes-private")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let outside = sibling.appendingPathComponent("secret.txt")
        try "synthetic outside fixture".write(to: outside, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for path in [outside.path, link.path] {
            try add(stores, source: "allowed", path: path, text: "target outside", vector: [1, 0])
        }
        let retriever = HybridRetriever(stores: stores, embedder: ScopeEmbedder(),
            sources: [IndexSource(id: "allowed", name: "Allowed", url: root)], enforceSourceScope: true)
        #expect(try await retriever.retrieve(query: "target", limit: 10).isEmpty)
        #expect(try stores.allDocuments().count == 2)
    }

    @Test func excludedHitsCannotCrowdEligibleHitsOutOfEitherTopTwentyArm() async throws {
        let stores = try inMemoryStores()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<30 {
            try add(stores, source: "removed", path: root.appendingPathComponent("excluded\(i).txt").path,
                    text: "needle", vector: [1, 0])
        }
        try add(stores, source: "allowed", path: root.appendingPathComponent("keyword.txt").path,
                text: "needle " + String(repeating: "filler ", count: 500))
        try add(stores, source: "allowed", path: root.appendingPathComponent("vector.txt").path,
                text: "semantic eligible", vector: [0, 1])
        let retriever = HybridRetriever(stores: stores, embedder: ScopeEmbedder(),
            sources: [IndexSource(id: "allowed", name: "Allowed", url: root)], enforceSourceScope: true)
        let result = try await retriever.retrieve(query: "needle", limit: 10)
        #expect(result.count == 2)
        #expect(result.contains { $0.text == "semantic eligible" })
        #expect(result.allSatisfy { $0.origin.hasPrefix("Allowed/") })
    }

    @Test func backfillReadsOnlyExplicitlyAllowedSources() async throws {
        let stores = try inMemoryStores()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for source in ["allowed", "removed"] {
            let file = root.appendingPathComponent("\(source).txt")
            try "\(source) fixture text".write(to: file, atomically: true, encoding: .utf8)
            try add(stores, source: source, path: file.path, text: "cached \(source)")
        }
        let embedder = ScopeEmbedder()
        let indexer = Indexer(stores: stores, embedder: embedder)
        try await indexer.embedMissing(allowedSourceIDs: ["allowed"])
        #expect(await embedder.inputs() == ["allowed fixture text"])
        let documents = try stores.allDocuments()
        let embedded = try stores.chunksWithEmbeddings()
        #expect(embedded.count == 1)
        #expect(documents.first { $0.id == embedded.first?.documentID }?.source == "allowed")
        #expect(documents.count == 2)
    }

    @Test func reregisteredRootReassignsUnchangedDocumentsToNewSource() async throws {
        let stores = try inMemoryStores()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("same.txt")
        try "unchanged fixture text".write(to: file, atomically: true, encoding: .utf8)
        let indexer = Indexer(stores: stores, embedder: ScopeEmbedder())
        try await indexer.fullScan(sources: [IndexSource(id: "old", name: "Old", url: root)])
        try await indexer.fullScan(sources: [IndexSource(id: "new", name: "New", url: root)])
        #expect(try stores.allDocuments().count == 1)
        #expect(try stores.document(path: file.path)?.source == "new")
    }

    @Test func cancelledScanDoesNotCommitOrPruneAndRejectsOverlappingScan() async throws {
        let stores = try inMemoryStores()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("new.txt")
        try "new fixture text".write(to: file, atomically: true, encoding: .utf8)
        let absent = root.appendingPathComponent("old.txt")
        try add(stores, source: "allowed", path: absent.path, text: "old cached text")
        let source = IndexSource(id: "allowed", name: "Allowed", url: root)
        let embedder = PausedScopeEmbedder()
        let indexer = Indexer(stores: stores, embedder: embedder)
        let scan = Task { try await indexer.fullScan(sources: [source]) }
        await embedder.waitUntilStarted()
        do {
            try await indexer.fullScan(sources: [source])
            Issue.record("Concurrent scan should have been rejected")
        } catch IndexerWorkError.alreadyRunning { }
        scan.cancel()
        await embedder.release()
        do {
            try await scan.value
            Issue.record("Cancelled scan should throw CancellationError")
        } catch is CancellationError { }
        #expect(try stores.document(path: file.path) == nil)
        #expect(try stores.document(path: absent.path) != nil)
    }
}
