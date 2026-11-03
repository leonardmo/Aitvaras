import Foundation
import AitvarasCore
import AitvarasStore
import Synchronization
import Testing
@testable import AitvarasRAG

/// Deterministic embedder for tests: shared topic markers map to the same
/// dimension so cross-language "semantic" matches are testable without a
/// real model.
private actor FakeEmbedder: EmbeddingEngine {
    let identifier = "fake"
    let dimensions = 8
    private var failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    func setFailing(_ value: Bool) {
        failing = value
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        guard !failing else { throw RAGError.embedderUnavailable(status: -1) }
        return texts.map(Self.vector(for:))
    }

    static func vector(for text: String) -> [Float] {
        let lower = text.lowercased()
        var v = [Float](repeating: 0, count: 8)
        let topics: [[String]] = [
            ["cat", "katze", "feline"],
            ["network", "netzwerk", "router"],
            ["garden", "garten", "plants"]
        ]
        for (dim, markers) in topics.enumerated() where markers.contains(where: lower.contains) {
            v[dim] = 1
        }
        // Small character-distribution residual so distinct texts never collapse
        // onto identical vectors, without swamping the topic dimensions.
        var residual = [Float](repeating: 0, count: 5)
        for byte in lower.utf8 { residual[Int(byte % 5)] += 1 }
        let norm = residual.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 {
            for i in 0..<5 { v[3 + i] += 0.3 * residual[i] / norm }
        }
        return v
    }
}

private actor ShortEmbedder: EmbeddingEngine {
    let identifier = "short"
    let dimensions = 8

    func embed(texts: [String]) async throws -> [[Float]] {
        Array(texts.dropLast()).map(FakeEmbedder.vector(for:))
    }
}

@Suite struct RAGTests {

    // MARK: Chunkers

    @Test func markdownChunkerTracksHeadingPath() {
        let doc = """
        # ML Notes

        Intro paragraph.

        ## Backprop

        Chain rule everywhere.
        """
        let pieces = Chunker.markdown(doc)
        #expect(pieces.count == 2)
        #expect(pieces[0].context == "ML Notes")
        #expect(pieces[0].text == "Intro paragraph.")
        #expect(pieces[1].context == "ML Notes › Backprop")
        #expect(pieces[1].text == "Chain rule everywhere.")
    }

    @Test func markdownHeadingSiblingsReplaceEachOtherInPath() {
        let doc = """
        # Root
        ## First
        alpha section body
        ### Deep
        deep body
        ## Second
        beta section body
        """
        let contexts = Chunker.markdown(doc).compactMap(\.context)
        #expect(contexts.contains("Root › First"))
        #expect(contexts.contains("Root › First › Deep"))
        #expect(contexts.contains("Root › Second"))
        #expect(!contexts.contains { $0.contains("First › Second") || $0.contains("Deep › Second") })
    }

    @Test func markdownSplitsLongSectionsAtParagraphBoundaries() {
        let paragraph = String(repeating: "lorem ipsum dolor sit amet ", count: 15)
            .trimmingCharacters(in: .whitespaces)
        let body = Array(repeating: paragraph, count: 6).joined(separator: "\n\n")
        let pieces = Chunker.markdown("# Long\n\n" + body)
        #expect(pieces.count >= 2)
        #expect(pieces.allSatisfy { $0.context == "Long" })
        #expect(pieces.allSatisfy { $0.text.count >= Chunker.minSize })
        #expect(pieces.allSatisfy { $0.text.count <= Chunker.targetSize + paragraph.count })
    }

    @Test func codeChunkerSplitsAtTopLevelDeclarations() {
        let filler = (0..<12).map { "    print(\"filler line number \($0)\")" }.joined(separator: "\n")
        let code = "func alpha() {\n\(filler)\n}\n\npublic func beta() {\n\(filler)\n}"
        let pieces = Chunker.code(code)
        #expect(pieces.count == 2)
        #expect(pieces[0].text.contains("alpha"))
        #expect(!pieces[0].text.contains("beta"))
        #expect(pieces[1].text.contains("beta"))
        #expect(pieces[0].context == "lines 1–15")
        #expect(pieces[1].context?.hasPrefix("lines 16–") == true)
    }

    @Test func codeChunkerFallsBackToOverlappingWindows() {
        let code = (1...150).map { "value \($0)" }.joined(separator: "\n")
        let pieces = Chunker.code(code)
        #expect(pieces.count == 3)
        #expect(pieces[0].context == "lines 1–60")
        #expect(pieces[1].context == "lines 51–110")
        #expect(pieces[2].context == "lines 101–150")
        #expect(pieces[1].text.hasPrefix("value 51"))
    }

    @Test func plainTextChunkerPacksParagraphs() {
        let paragraph = String(repeating: "word ", count: 100).trimmingCharacters(in: .whitespaces)
        let pieces = Chunker.plainText([paragraph, paragraph, paragraph, paragraph].joined(separator: "\n\n"))
        #expect(pieces.count >= 2)
        #expect(pieces.allSatisfy { $0.context == nil })
    }

    // MARK: Indexer

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-rag-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolved (/var → /private/var) so paths compare equal to what the
        // indexer stores.
        return dir.resolvingSymlinksInPath()
    }

    @Test func indexerScansEmbedsSkipsAndPrunes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let noteURL = dir.appendingPathComponent("notes.md")
        try "# Cats\n\nDie Katze schläft gern in der Sonne.".write(to: noteURL, atomically: true, encoding: .utf8)
        let codeURL = dir.appendingPathComponent("net.swift")
        try "func connect() {\n    startRouterSession()\n}".write(to: codeURL, atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("image.xyz"), atomically: true, encoding: .utf8)

        let stores = Stores(db: try AitvarasDatabase(url: nil))
        let progress = Mutex<[IndexProgress]>([])
        let indexer = Indexer(stores: stores, embedder: FakeEmbedder()) { p in
            progress.withLock { $0.append(p) }
        }
        let source = IndexSource(id: "test", name: "Test", url: dir)

        try await indexer.fullScan(sources: [source])
        var stats = try stores.chunkStats()
        #expect(stats.documents == 2)
        #expect(stats.chunks >= 2)
        #expect(stats.embedded == stats.chunks)
        let lastProgress = progress.withLock { $0.last }
        #expect(lastProgress?.processed == 2)
        #expect(lastProgress?.total == 2)

        // Unchanged rescan keeps document identity (mtime skip).
        let docID = try #require(try stores.document(path: noteURL.path)).id
        try await indexer.fullScan(sources: [source])
        #expect(try stores.document(path: noteURL.path)?.id == docID)

        // Vanished file is pruned.
        try FileManager.default.removeItem(at: codeURL)
        try await indexer.fullScan(sources: [source])
        stats = try stores.chunkStats()
        #expect(stats.documents == 1)
        #expect(try stores.document(path: codeURL.path) == nil)
    }

    @Test func indexerWorksWithoutEmbedderAndBackfillsLater() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Cats\n\nDie Katze schläft gern in der Sonne."
            .write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let stores = Stores(db: try AitvarasDatabase(url: nil))
        let embedder = FakeEmbedder(failing: true)
        let indexer = Indexer(stores: stores, embedder: embedder)
        let source = IndexSource(id: "test", name: "Test", url: dir)

        try await indexer.fullScan(sources: [source])
        var stats = try stores.chunkStats()
        #expect(stats.documents == 1)
        #expect(stats.embedded == 0)
        // Keyword search works without embeddings.
        #expect(try !stores.keywordSearch("Katze", limit: 5).isEmpty)
        // Backfill fails while the embedder is still down.
        await #expect(throws: RAGError.self) { try await indexer.embedMissing() }

        await embedder.setFailing(false)
        try await indexer.embedMissing()
        stats = try stores.chunkStats()
        #expect(stats.chunks > 0)
        #expect(stats.embedded == stats.chunks)
    }

    @Test func unavailableSourceDoesNotPruneTrustedDocuments() async throws {
        let stores = try inMemoryStores()
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let path = missingRoot.appendingPathComponent("notes.md").path
        let doc = RAGDocument(source: "offline", path: path, mtime: 1, contentHash: "old")
        try stores.upsertDocument(
            doc, chunks: [RAGChunk(documentID: doc.id, ord: 0, text: "trusted old note")])
        let indexer = Indexer(stores: stores, embedder: FakeEmbedder())

        await #expect(throws: RAGError.self) {
            try await indexer.fullScan(sources: [
                IndexSource(id: "offline", name: "Offline", url: missingRoot)
            ])
        }
        #expect(try stores.document(path: path)?.id == doc.id)
        #expect(try stores.chunkStats().chunks == 1)
    }

    @Test func databaseWriteFailureIsReportedByFullScan() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "A durable note long enough to become a searchable chunk in the index."
            .write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let stores = try inMemoryStores()
        try await stores.db.queue.write { dbc in
            try dbc.execute(sql: """
                CREATE TRIGGER reject_rag_document
                BEFORE INSERT ON ragDocument
                BEGIN
                    SELECT RAISE(ABORT, 'injected index write failure');
                END
                """)
        }
        let indexer = Indexer(stores: stores, embedder: FakeEmbedder())

        await #expect(throws: RAGError.self) {
            try await indexer.fullScan(sources: [IndexSource(id: "test", name: "Test", url: dir)])
        }
        #expect(try stores.chunkStats().documents == 0)
    }

    @Test func unreadablePDFIsReportedInsteadOfIndexedAsEmpty() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("this is not a PDF".utf8)
            .write(to: dir.appendingPathComponent("broken.pdf"))
        let stores = try inMemoryStores()
        let indexer = Indexer(stores: stores, embedder: FakeEmbedder())

        await #expect(throws: RAGError.self) {
            try await indexer.fullScan(sources: [
                IndexSource(id: "pdfs", name: "PDFs", url: dir)
            ])
        }
        #expect(try stores.chunkStats().documents == 0)
        #expect(try stores.chunkStats().chunks == 0)
    }

    @Test func invalidUTF8TextIsRejectedInsteadOfIndexedAsReplacementCharacters() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0xFF, 0xFE, 0xFD]).write(to: dir.appendingPathComponent("binary.txt"))
        let stores = try inMemoryStores()
        let indexer = Indexer(stores: stores, embedder: FakeEmbedder())

        await #expect(throws: RAGError.self) {
            try await indexer.fullScan(sources: [
                IndexSource(id: "text", name: "Text", url: dir)
            ])
        }
        #expect(try stores.chunkStats().documents == 0)
    }

    @Test func embeddingBackfillRechecksFileSizeBeforeReading() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("grew.txt")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(Indexer.maxFileSize + 1))
        try handle.close()

        let stores = try inMemoryStores()
        let document = RAGDocument(
            source: "test", path: file.path, mtime: 1, contentHash: "old")
        try stores.upsertDocument(document, chunks: [
            RAGChunk(documentID: document.id, ord: 0, text: "old searchable text")
        ])
        let indexer = Indexer(stores: stores, embedder: FakeEmbedder())

        await #expect(throws: RAGError.self) {
            try await indexer.embedMissing()
        }
        #expect(try stores.keywordSearch("searchable", limit: 5).count == 1)
    }

    @Test func symlinkCannotPullKnowledgeFromOutsideSelectedFolder() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let selected = parent.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let outside = parent.appendingPathComponent("outside.txt")
        try "Private text outside the selected knowledge folder."
            .write(to: outside, atomically: true, encoding: .utf8)
        try "Normal searchable text inside the selected folder."
            .write(to: selected.appendingPathComponent("inside.txt"),
                   atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: selected.appendingPathComponent("linked.txt"),
            withDestinationURL: outside)
        let stores = try inMemoryStores()
        let indexer = Indexer(stores: stores, embedder: FakeEmbedder())

        try await indexer.fullScan(sources: [
            IndexSource(id: "selected", name: "Selected", url: selected)
        ])

        #expect(try stores.chunkStats().documents == 1)
        #expect(try stores.document(path: outside.path) == nil)
        #expect(try stores.keywordSearch("Private", limit: 5).isEmpty)
        #expect(try !stores.keywordSearch("Normal", limit: 5).isEmpty)
    }

    @Test func shortEmbeddingBatchStaysEntirelyKeywordOnly() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "First paragraph about a cat and its daily routine.\n\nSecond paragraph about a network router and firmware."
            .write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let stores = try inMemoryStores()
        let indexer = Indexer(stores: stores, embedder: ShortEmbedder())

        try await indexer.fullScan(sources: [IndexSource(id: "test", name: "Test", url: dir)])
        let stats = try stores.chunkStats()
        #expect(stats.chunks > 0)
        #expect(stats.embedded == 0)
        await #expect(throws: RAGError.self) { try await indexer.embedMissing() }
    }

    @Test func removingSourceCommitsConfigurationAndIndexCleanupTogether() throws {
        let stores = try inMemoryStores()
        let removed = RAGDocument(
            source: "removed", path: "/tmp/removed.md", mtime: 1, contentHash: "a")
        let kept = RAGDocument(
            source: "kept", path: "/tmp/kept.md", mtime: 1, contentHash: "b")
        try stores.upsertDocument(removed, chunks: [
            RAGChunk(documentID: removed.id, ord: 0, text: "obsolete aardvark note")
        ])
        try stores.upsertDocument(kept, chunks: [
            RAGChunk(documentID: kept.id, ord: 0, text: "current badger note")
        ])
        try stores.setValue("old-config", forKey: "rag.sources")

        try stores.setValue(
            "new-config", forKey: "rag.sources", removingRAGDocumentsFrom: "removed")

        #expect(try stores.value(forKey: "rag.sources") == "new-config")
        #expect(try stores.allDocuments().map(\.id) == [kept.id])
        #expect(try stores.keywordSearch("aardvark", limit: 5).isEmpty)
        #expect(try stores.keywordSearch("badger", limit: 5).map(\.chunkID).count == 1)
    }

    @Test func failedSourceRemovalRollsBackConfigurationAndSearchIndex() throws {
        let stores = try inMemoryStores()
        let doc = RAGDocument(
            source: "blocked", path: "/tmp/blocked.md", mtime: 1, contentHash: "a")
        try stores.upsertDocument(doc, chunks: [
            RAGChunk(documentID: doc.id, ord: 0, text: "durable capybara note")
        ])
        try stores.setValue("old-config", forKey: "rag.sources")
        try stores.db.queue.write { dbc in
            try dbc.execute(sql: """
                CREATE TRIGGER reject_source_removal
                BEFORE DELETE ON ragDocument
                WHEN OLD.source = 'blocked'
                BEGIN
                    SELECT RAISE(ABORT, 'injected source removal failure');
                END
                """)
        }

        #expect(throws: (any Error).self) {
            try stores.setValue(
                "new-config", forKey: "rag.sources", removingRAGDocumentsFrom: "blocked")
        }
        #expect(try stores.value(forKey: "rag.sources") == "old-config")
        #expect(try stores.document(path: doc.path)?.id == doc.id)
        #expect(try stores.keywordSearch("capybara", limit: 5).map(\.chunkID).count == 1)
    }

    @Test func replacingAndRemovingDocumentPrunesStaleSearchRows() throws {
        let stores = try inMemoryStores()
        let doc = RAGDocument(
            source: "notes", path: "/tmp/changing.md", mtime: 1, contentHash: "old")
        try stores.upsertDocument(doc, chunks: [
            RAGChunk(documentID: doc.id, ord: 0, text: "legacy dragonfruit note")
        ])
        #expect(try stores.keywordSearch("dragonfruit", limit: 5).count == 1)

        let replacement = RAGDocument(
            id: doc.id, source: doc.source, path: doc.path, mtime: 2, contentHash: "new")
        try stores.upsertDocument(replacement, chunks: [
            RAGChunk(documentID: doc.id, ord: 0, text: "current elderberry note")
        ])
        #expect(try stores.keywordSearch("dragonfruit", limit: 5).isEmpty)
        #expect(try stores.keywordSearch("elderberry", limit: 5).count == 1)

        try stores.removeDocument(path: doc.path)
        #expect(try stores.keywordSearch("elderberry", limit: 5).isEmpty)
    }

    @Test func fileEventsReindexAndPruneWithoutWaitingForPoll() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stores = Stores(db: try AitvarasDatabase(url: nil))
        try stores.saveBackgroundWorkPolicy(BackgroundWorkPolicy(reviewed: true, allowed: [.indexing]))
        let indexer = Indexer(stores: stores, embedder: FakeEmbedder())
        let source = IndexSource(id: "watch", name: "Watch", url: dir)
        await indexer.startWatching(
            sources: [source], debounce: .milliseconds(100),
            fallbackInterval: .seconds(30))
        defer { Task { await indexer.stopWatching() } }

        let note = dir.appendingPathComponent("live.md")
        try "# Live\n\nA watched cat note."
            .write(to: note, atomically: true, encoding: .utf8)
        let indexed = await eventually {
            (try? stores.document(path: note.path)) != nil
        }
        #expect(indexed)

        try FileManager.default.removeItem(at: note)
        let pruned = await eventually {
            (try? stores.document(path: note.path)) == nil
        }
        #expect(pruned)
        await indexer.stopWatching()
    }

    @Test func watcherReportsRefreshFailures() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-watch-\(UUID().uuidString)")
        let stores = try inMemoryStores()
        try stores.saveBackgroundWorkPolicy(BackgroundWorkPolicy(reviewed: true, allowed: [.indexing]))
        let errors = Mutex<[String]>([])
        let indexer = Indexer(
            stores: stores, embedder: FakeEmbedder(),
            onError: { message in errors.withLock { $0.append(message) } })
        await indexer.startWatching(
            sources: [IndexSource(id: "missing", name: "Missing", url: missing)],
            debounce: .milliseconds(10), fallbackInterval: .milliseconds(25))
        defer { Task { await indexer.stopWatching() } }

        let reported = await eventually {
            errors.withLock { !$0.isEmpty }
        }
        #expect(reported)
        #expect(errors.withLock { $0.first?.contains("unavailable") == true })
        await indexer.stopWatching()
    }

    private func eventually(
        timeout: Duration = .seconds(5),
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: Retriever

    @Test func retrieverFusesVectorAndKeywordArms() async throws {
        let stores = Stores(db: try AitvarasDatabase(url: nil))
        let doc = RAGDocument(source: "test", path: "/tmp/vault/notes.md", mtime: 0, contentHash: "h")

        var bothArms = RAGChunk(documentID: doc.id, ord: 0,
                                text: "The network router needs a firmware update",
                                context: "Home › Network")
        bothArms.embeddingVector = FakeEmbedder.vector(for: bothArms.text)
        let keywordOnly = RAGChunk(documentID: doc.id, ord: 1,
                                   text: "seating plan near the router closet for the wedding")
        var vectorOnly = RAGChunk(documentID: doc.id, ord: 2,
                                  text: "Das Netzwerk ist heute wieder langsam")
        vectorOnly.embeddingVector = FakeEmbedder.vector(for: vectorOnly.text)
        var distractor = RAGChunk(documentID: doc.id, ord: 3,
                                  text: "garden plants watering schedule for spring")
        distractor.embeddingVector = FakeEmbedder.vector(for: distractor.text)
        try stores.upsertDocument(doc, chunks: [bothArms, keywordOnly, vectorOnly, distractor])

        let sources = [IndexSource(id: "test", name: "Vault", url: URL(fileURLWithPath: "/tmp/vault"))]
        let retriever = HybridRetriever(stores: stores, embedder: FakeEmbedder(), sources: sources)
        let results = try await retriever.retrieve(query: "network router", limit: 3)

        #expect(results.count == 3)
        // Hit in both arms wins RRF over single-arm hits.
        #expect(results[0].text == bothArms.text)
        #expect(results[0].origin == "Vault/notes.md § Home › Network")
        let texts = Set(results.map(\.text))
        // Semantic match without keyword overlap surfaces via the vector arm...
        #expect(texts.contains(vectorOnly.text))
        // ...and the un-embedded chunk via the keyword arm; the off-topic
        // distractor is what gets cut.
        #expect(texts.contains(keywordOnly.text))
        #expect(!texts.contains(distractor.text))
        #expect(results[0].score > results[1].score)
    }

    @Test func retrieverFallsBackToKeywordsWhenEmbedderIsDown() async throws {
        let stores = Stores(db: try AitvarasDatabase(url: nil))
        let doc = RAGDocument(source: "test", path: "/tmp/vault/net.md", mtime: 0, contentHash: "h")
        let chunk = RAGChunk(documentID: doc.id, ord: 0, text: "low level networking in C")
        try stores.upsertDocument(doc, chunks: [chunk])

        let retriever = HybridRetriever(stores: stores, embedder: FakeEmbedder(failing: true))
        let results = try await retriever.retrieve(query: "networking", limit: 5)
        #expect(results.count == 1)
        #expect(results[0].text == chunk.text)
    }

    @Test func retrieverSurvivesPunctuationHeavyQueries() async throws {
        let stores = Stores(db: try AitvarasDatabase(url: nil))
        let doc = RAGDocument(source: "test", path: "/tmp/vault/net.md", mtime: 0, contentHash: "h")
        let chunk = RAGChunk(documentID: doc.id, ord: 0, text: "low level networking in C")
        try stores.upsertDocument(doc, chunks: [chunk])
        let retriever = HybridRetriever(stores: stores, embedder: FakeEmbedder())

        // FTS5 syntax characters must be neutralized, not crash the query.
        let results = try await retriever.retrieve(query: "C++ & networking?", limit: 5)
        #expect(results.contains { $0.text == chunk.text })

        // All-punctuation query drops the keyword arm entirely (chunk has no
        // embedding, so the vector arm is empty too) — no results, no throw.
        let empty = try await retriever.retrieve(query: "+++ ???", limit: 5)
        #expect(empty.isEmpty)
    }

    @Test func retrieverReportsStorageFailureInsteadOfLookingEmpty() async throws {
        let stores = try inMemoryStores()
        let retriever = HybridRetriever(stores: stores, embedder: FakeEmbedder(failing: true))
        try stores.db.queue.close()

        await #expect(throws: (any Error).self) {
            try await retriever.retrieve(query: "network", limit: 5)
        }
    }
}
