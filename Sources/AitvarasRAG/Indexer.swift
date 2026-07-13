import CryptoKit
import Foundation
import AitvarasCore
import AitvarasStore

/// A user-added directory Aitvaras indexes (D11), e.g. a notes vault or a code repo.
public struct IndexSource: Sendable, Equatable {
    public var id: String
    public var name: String
    public var url: URL
    public var extensions: Set<String>

    public init(id: String, name: String, url: URL,
                extensions: Set<String> = IndexSource.defaultExtensions) {
        self.id = id
        self.name = name
        self.url = url
        self.extensions = extensions
    }

    public static let defaultExtensions: Set<String> = [
        "md", "txt", "markdown", "pdf", "swift", "py", "ts", "js", "tsx", "jsx",
        "c", "cpp", "h", "hpp", "java", "rs", "go", "css", "html", "yml", "yaml",
        "toml", "tex"
    ]
}

public struct IndexProgress: Sendable, Equatable {
    public var processed: Int
    public var total: Int
    public var currentPath: String

    public init(processed: Int, total: Int, currentPath: String) {
        self.processed = processed
        self.total = total
        self.currentPath = currentPath
    }
}

/// Walks the configured sources, chunks + embeds changed files, and prunes
/// vanished ones (D11). If the embedder is unreachable the scan still indexes
/// documents *without* embeddings — keyword search keeps working — and
/// `embedMissing()` fills them in later. A document "needs embedding" iff
/// none of its chunks carries one (embedding failure is all-or-nothing per
/// document here), so that state survives restarts without extra bookkeeping.
public actor Indexer {
    public typealias ProgressHandler = @Sendable (IndexProgress) -> Void

    private let stores: Stores
    private let embedder: any EmbeddingEngine
    private let onProgress: ProgressHandler?
    private var watchTask: Task<Void, Never>?
    /// Set on the first embed failure of a scan so remaining files skip the
    /// (timeout-prone) embed call instead of stalling on each one.
    private var embedderDown = false

    private static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData"]
    private static let maxFileSize = 10 * 1024 * 1024
    private static let maxPDFSize = 50 * 1024 * 1024
    private static let codeExtensions: Set<String> = [
        "swift", "py", "ts", "js", "tsx", "jsx", "c", "cpp", "h", "hpp", "java", "rs", "go"
    ]

    public init(stores: Stores, embedder: any EmbeddingEngine, onProgress: ProgressHandler? = nil) {
        self.stores = stores
        self.embedder = embedder
        self.onProgress = onProgress
    }

    deinit {
        watchTask?.cancel()
    }

    // MARK: Full scan

    public func fullScan(sources: [IndexSource]) async throws {
        embedderDown = false
        let plans = sources.map { ($0, Self.candidateFiles(in: $0)) }
        let total = plans.reduce(0) { $0 + $1.1.count }
        var processed = 0

        for (source, files) in plans {
            var seen: Set<String> = []
            for url in files {
                seen.insert(url.path)
                processed += 1
                onProgress?(IndexProgress(processed: processed, total: total, currentPath: url.path))
                do {
                    try await index(url: url, source: source)
                } catch {
                    continue   // unreadable file — skip, keep scanning
                }
            }
            for doc in try stores.allDocuments(source: source.id) where !seen.contains(doc.path) {
                try stores.removeDocument(path: doc.path)
            }
        }
    }

    private func index(url: URL, source: IndexSource) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let existing = try stores.document(path: url.path)
        if let existing, existing.mtime == mtime { return }

        let data = try Data(contentsOf: url)
        let hash = Self.sha256(data)
        if let existing, existing.contentHash == hash { return }

        let doc = RAGDocument(id: existing?.id ?? UUID(), source: source.id,
                              path: url.path, mtime: mtime, contentHash: hash)
        let chunks = await makeChunks(Self.pieces(for: url, data: data), documentID: doc.id)
        try stores.upsertDocument(doc, chunks: chunks)
    }

    private func makeChunks(_ pieces: [Chunker.Piece], documentID: UUID) async -> [RAGChunk] {
        var vectors: [[Float]]?
        if !embedderDown, !pieces.isEmpty {
            do {
                vectors = try await embedder.embed(texts: pieces.map(\.text))
            } catch {
                embedderDown = true   // index without embeddings; embedMissing() fills in
            }
        }
        return pieces.enumerated().map { i, piece in
            var chunk = RAGChunk(documentID: documentID, ord: i, text: piece.text, context: piece.context)
            if let vectors, i < vectors.count { chunk.embeddingVector = vectors[i] }
            return chunk
        }
    }

    // MARK: Embedding backfill

    /// Re-embeds every document whose chunks all lack embeddings (i.e. was
    /// indexed while the embedder was down). Throws on the first embed
    /// failure so callers know the embedder is still unreachable.
    public func embedMissing() async throws {
        embedderDown = false
        let embeddedDocIDs = Set(try stores.chunksWithEmbeddings().map(\.documentID))
        for doc in try stores.allDocuments() where !embeddedDocIDs.contains(doc.id) {
            let url = URL(fileURLWithPath: doc.path)
            guard let data = try? Data(contentsOf: url) else { continue }
            let pieces = Self.pieces(for: url, data: data)
            guard !pieces.isEmpty else { continue }

            let vectors = try await embedder.embed(texts: pieces.map(\.text))
            let attributes = try? FileManager.default.attributesOfItem(atPath: doc.path)
            let mtime = ((attributes?[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? doc.mtime
            let updated = RAGDocument(id: doc.id, source: doc.source, path: doc.path,
                                      mtime: mtime, contentHash: Self.sha256(data))
            let chunks = pieces.enumerated().map { i, piece in
                var chunk = RAGChunk(documentID: doc.id, ord: i, text: piece.text, context: piece.context)
                if i < vectors.count { chunk.embeddingVector = vectors[i] }
                return chunk
            }
            try stores.upsertDocument(updated, chunks: chunks)
        }
        try await embedMissingFacts()
    }

    /// Backfill memory facts saved while the embedder was unreachable —
    /// without this a fact written offline stays keyword-only forever.
    public func embedMissingFacts() async throws {
        let missing = try stores.factsMissingEmbedding()
        guard !missing.isEmpty else { return }
        let vectors = try await embedder.embed(texts: missing.map(\.searchText))
        for (fact, vector) in zip(missing, vectors) {
            try stores.saveFactEmbedding(fact.id, vector: vector)
        }
    }

    // MARK: Watching

    /// Re-scans on a timer; cheap because unchanged files are skipped by
    /// mtime. FSEvents-based invalidation can replace this later without
    /// changing the public surface.
    public func startWatching(sources: [IndexSource], interval: Duration = .seconds(300)) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                try? await self.fullScan(sources: sources)
            }
        }
    }

    public func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    // MARK: File discovery

    private static func candidateFiles(in source: IndexSource) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: source.url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard values.isRegularFile == true, source.extensions.contains(ext) else { continue }
            let limit = ext == "pdf" ? maxPDFSize : maxFileSize
            if let size = values.fileSize, size > limit { continue }
            // Symlink-resolved so stored paths are stable regardless of how
            // the source root was spelled (/var vs /private/var etc.).
            files.append(url.resolvingSymlinksInPath())
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func pieces(for url: URL, data: Data) -> [Chunker.Piece] {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown":
            return Chunker.markdown(String(decoding: data, as: UTF8.self))
        case "pdf":
            return Chunker.pdf(at: url)
        case _ where codeExtensions.contains(ext):
            return Chunker.code(String(decoding: data, as: UTF8.self))
        default:
            return Chunker.plainText(String(decoding: data, as: UTF8.self))
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
