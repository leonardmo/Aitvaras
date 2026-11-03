import CryptoKit
import Foundation
import AitvarasCore
import AitvarasStore

public enum IndexerWorkError: Error, LocalizedError, Sendable {
    case alreadyRunning
    public var errorDescription: String? { "Knowledge indexing is already running. Wait for it to finish or cancel it first." }
}

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
    public typealias ErrorHandler = @Sendable (String) -> Void

    private let stores: Stores
    private let embedder: any EmbeddingEngine
    private let reporter: ActivityReporter?
    private var scanRunID: UUID?
    private let onProgress: ProgressHandler?
    private let onError: ErrorHandler?
    private var watchTask: Task<Void, Never>?
    private var fileWatcher: FileSystemWatcher?
    /// Set on the first embed failure of a scan so remaining files skip the
    /// (timeout-prone) embed call instead of stalling on each one.
    private var embedderDown = false
    private var workInProgress = false

    private static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData"]
    static let maxFileSize = 10 * 1024 * 1024
    static let maxPDFSize = 50 * 1024 * 1024
    private static let codeExtensions: Set<String> = [
        "swift", "py", "ts", "js", "tsx", "jsx", "c", "cpp", "h", "hpp", "java", "rs", "go"
    ]

    public init(stores: Stores, embedder: any EmbeddingEngine,
                reporter: ActivityReporter? = nil,
                onProgress: ProgressHandler? = nil, onError: ErrorHandler? = nil) {
        self.stores = stores
        self.embedder = embedder
        self.reporter = reporter
        self.onProgress = onProgress
        self.onError = onError
    }

    deinit {
        watchTask?.cancel()
        fileWatcher?.stop()
    }

    // MARK: Full scan

    public func fullScan(sources: [IndexSource]) async throws {
        try Task.checkCancellation()
        if ActivityTaskContext.trigger != .manual {
            guard reporter?.failureMessage == nil,
                  (try stores.backgroundWorkPolicy()).permits(.indexing) else { return }
        }
        guard !workInProgress else { throw IndexerWorkError.alreadyRunning }
        workInProgress = true
        defer { workInProgress = false; scanRunID = nil }
        do {
            try await performScan(sources: sources)
            if let scanRunID { reporter?.finish(id: scanRunID, state: .succeeded,
                outcome: embedderDown ? "Keyword index updated; embedding provider unavailable" : "Search index updated") }
        } catch {
            if let scanRunID { reporter?.finish(id: scanRunID,
                state: error is CancellationError ? .cancelled : .failed,
                outcome: error is CancellationError ? "Index update stopped" : "Some files could not be indexed; previous data retained where possible") }
            throw error
        }
    }

    private func beginChangedScanIfNeeded() {
        guard ActivityTaskContext.trigger == .automatic, scanRunID == nil else { return }
        scanRunID = reporter?.begin(ActivityRun(category: .knowledge, trigger: .automatic,
            title: "Update changed sources", stage: "Indexing changed files",
            executionLocation: "This Mac", dataAccess: "Available registered folders",
            dataDestination: "Local search index; configured embedding provider"))
    }

    private func performScan(sources: [IndexSource]) async throws {
        embedderDown = false
        // Resolve every root before mutating the index. An unmounted or
        // unreadable source must not look like an empty folder and prune all
        // previously trusted documents from that source.
        let plans = try sources.map { ($0, try Self.candidateFiles(in: $0)) }
        let total = plans.reduce(0) { $0 + $1.1.count }
        var processed = 0
        var failures: [String] = []

        for (source, files) in plans {
            var seen: Set<String> = []
            for url in files {
                try Task.checkCancellation()
                seen.insert(url.path)
                processed += 1
                onProgress?(IndexProgress(processed: processed, total: total, currentPath: url.path))
                do {
                    try await index(url: url, source: source)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            for doc in try stores.allDocuments(source: source.id) where !seen.contains(doc.path) {
                try Task.checkCancellation()
                beginChangedScanIfNeeded()
                try stores.removeDocument(path: doc.path)
            }
        }
        if let first = failures.first {
            throw RAGError.indexingFailures(count: failures.count, first: first)
        }
    }

    private func index(url: URL, source: IndexSource) async throws {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let existing = try stores.document(path: url.path)
        if let existing, existing.source == source.id, existing.mtime == mtime { return }

        let data = try Self.checkedFileData(at: url)
        let hash = Self.sha256(data)
        if let existing, existing.source == source.id, existing.contentHash == hash { return }

        beginChangedScanIfNeeded()

        let doc = RAGDocument(id: existing?.id ?? UUID(), source: source.id,
                              path: url.path, mtime: mtime, contentHash: hash)
        let pieces = try Self.pieces(for: url, data: data)
        if url.pathExtension.lowercased() == "pdf", pieces.isEmpty {
            throw RAGError.noExtractableText(path: url.path)
        }
        if pieces.isEmpty {
            // An emptied text file must not leave its old searchable chunks
            // behind, but also is not an indexing failure worth warning on.
            try Task.checkCancellation()
            if existing != nil { try stores.removeDocument(path: url.path) }
            return
        }
        let chunks = try await makeChunks(pieces, documentID: doc.id)
        try Task.checkCancellation()
        try stores.upsertDocument(doc, chunks: chunks)
    }

    private func makeChunks(_ pieces: [Chunker.Piece], documentID: UUID) async throws -> [RAGChunk] {
        var vectors: [[Float]]?
        if !embedderDown, !pieces.isEmpty {
            do {
                vectors = try await validatedEmbeddings(for: pieces.map(\.text))
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
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
    public func embedMissing(allowedSourceIDs: Set<String>? = nil) async throws {
        try Task.checkCancellation()
        guard !workInProgress else { throw IndexerWorkError.alreadyRunning }
        workInProgress = true
        defer { workInProgress = false }
        embedderDown = false
        let embeddedDocIDs = Set(try stores.chunksWithEmbeddings().map(\.documentID))
        for doc in try stores.allDocuments() where !embeddedDocIDs.contains(doc.id) {
            try Task.checkCancellation()
            if let allowedSourceIDs, !allowedSourceIDs.contains(doc.source) { continue }
            let url = URL(fileURLWithPath: doc.path)
            guard FileManager.default.fileExists(atPath: doc.path) else { continue }
            let data = try Self.checkedFileData(at: url)
            let pieces = try Self.pieces(for: url, data: data)
            guard !pieces.isEmpty else { continue }

            let vectors = try await validatedEmbeddings(for: pieces.map(\.text))
            let attributes = try? FileManager.default.attributesOfItem(atPath: doc.path)
            let mtime = ((attributes?[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? doc.mtime
            let updated = RAGDocument(id: doc.id, source: doc.source, path: doc.path,
                                      mtime: mtime, contentHash: Self.sha256(data))
            let chunks = pieces.enumerated().map { i, piece in
                var chunk = RAGChunk(documentID: doc.id, ord: i, text: piece.text, context: piece.context)
                if i < vectors.count { chunk.embeddingVector = vectors[i] }
                return chunk
            }
            try Task.checkCancellation()
            try stores.upsertDocument(updated, chunks: chunks)
        }
        try await embedMissingFacts()
    }

    /// Backfill memory facts saved while the embedder was unreachable —
    /// without this a fact written offline stays keyword-only forever.
    public func embedMissingFacts() async throws {
        try Task.checkCancellation()
        let missing = try stores.factsMissingEmbedding()
        guard !missing.isEmpty else { return }
        let vectors = try await validatedEmbeddings(for: missing.map(\.searchText))
        for (fact, vector) in zip(missing, vectors) {
            try Task.checkCancellation()
            try stores.saveFactEmbedding(fact.id, vector: vector)
        }
    }

    private func validatedEmbeddings(for texts: [String]) async throws -> [[Float]] {
        try Task.checkCancellation()
        let vectors = try await embedder.embed(texts: texts)
        try Task.checkCancellation()
        guard vectors.count == texts.count else {
            throw RAGError.embeddingCountMismatch(expected: texts.count, got: vectors.count)
        }
        return vectors
    }

    // MARK: Watching

    private func scanWatchedSources(_ sources: [IndexSource]) async throws {
        guard reporter?.failureMessage == nil,
              (try stores.backgroundWorkPolicy()).permits(.indexing) else { return }
        try await ActivityTaskContext.$trigger.withValue(.automatic) {
            try await self.fullScan(sources: sources)
        }
    }

    /// Watches all source hierarchies recursively. FSEvents coalesces bursts,
    /// then the existing mtime/hash scan restores the authoritative state.
    /// A periodic scan remains only as a fallback if the OS stream cannot start.
    public func startWatching(
        sources: [IndexSource],
        debounce: Duration = .seconds(1),
        fallbackInterval: Duration = .seconds(300)
    ) {
        watchTask?.cancel()
        fileWatcher?.stop()
        fileWatcher = nil
        guard !sources.isEmpty else { return }
        guard reporter?.failureMessage == nil,
              (try? stores.backgroundWorkPolicy().permits(.indexing)) == true else { return }

        let watcher = FileSystemWatcher(paths: sources.map { $0.url.path })
        if watcher.start() {
            fileWatcher = watcher
            watchTask = Task { [weak self] in
                guard let self else { return }
                // Catch edits made while Aitvaras was closed before listening
                // for changes that happen during this run.
                do {
                    try await self.scanWatchedSources(sources)
                } catch is CancellationError { return }
                catch {
                    await self.reportWatchError(error)
                }
                for await _ in watcher.events {
                    do { try await Task.sleep(for: debounce) }
                    catch { return }
                    do {
                        try await self.scanWatchedSources(sources)
                    } catch is CancellationError { return }
                    catch {
                        await self.reportWatchError(error)
                    }
                }
            }
            return
        }

        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: fallbackInterval) }
                catch { return }
                guard let self else { return }
                do {
                    try await self.scanWatchedSources(sources)
                } catch is CancellationError { return }
                catch {
                    await self.reportWatchError(error)
                }
            }
        }
    }

    public func stopWatching() async {
        let previous = watchTask
        previous?.cancel()
        watchTask = nil
        fileWatcher?.stop()
        fileWatcher = nil
        await previous?.value
    }

    private func reportWatchError(_ error: Error) {
        onError?("Knowledge watcher could not refresh the index: \(error.localizedDescription)")
    }

    // MARK: File discovery

    private static func candidateFiles(in source: IndexSource) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RAGError.sourceUnavailable(path: source.url.path)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: source.url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw RAGError.sourceUnavailable(path: source.url.path)
        }

        let resolvedRoot = source.url.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path : resolvedRoot.path + "/"
        var files: Set<URL> = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
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
            // the source root was spelled (/var vs /private/var etc.). Never
            // follow a link outside the folder the user explicitly selected.
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootPrefix) else { continue }
            files.insert(resolved)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func pieces(for url: URL, data: Data) throws -> [Chunker.Piece] {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return Chunker.pdf(at: url) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RAGError.invalidTextEncoding(path: url.path)
        }
        switch ext {
        case "md", "markdown":
            return Chunker.markdown(text)
        case _ where codeExtensions.contains(ext):
            return Chunker.code(text)
        default:
            return Chunker.plainText(text)
        }
    }

    /// Read at most the configured limit plus one byte. Discovery also skips
    /// oversized files, but this second boundary closes the race where a file
    /// grows after enumeration and protects embedding backfills, which reopen
    /// previously indexed paths directly.
    static func checkedFileData(at url: URL) throws -> Data {
        let limit = url.pathExtension.lowercased() == "pdf" ? maxPDFSize : maxFileSize
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        let chunkSize = 1024 * 1024
        while data.count <= limit {
            try Task.checkCancellation()
            let remaining = limit + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(chunkSize, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= limit else {
            throw RAGError.fileTooLarge(path: url.path, maximumBytes: limit)
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
