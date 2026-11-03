import Foundation
import Darwin

/// Keeping original audio is explicit and independent of text capture.
public enum CaptureAudioRetention: String, Codable, CaseIterable, Sendable, Identifiable {
    case discard, sevenDays, untilDeleted
    public var id: String { rawValue }
    public var displayLabel: String {
        switch self {
        case .discard: "Discard audio"
        case .sevenDays: "Keep for 7 days"
        case .untilDeleted: "Keep until manually deleted"
        }
    }
    public func expiration(from date: Date) -> Date? {
        self == .sevenDays ? date.addingTimeInterval(7 * 24 * 60 * 60) : nil
    }
}

public enum CaptureAudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, systemAudio
    public var filename: String { rawValue + ".caf" }
    public var displayLabel: String { self == .microphone ? "Microphone" : "System audio" }
}

/// Deliberately contains no transcript, credentials, user labels, or paths.
public struct CaptureAudioManifest: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case recording, finalized, interrupted, failed }
    public struct Source: Codable, Equatable, Sendable {
        public var source: CaptureAudioSource
        public var sampleRate: Double
        public var channels: UInt32
        public var storedBitsPerChannel: Int = 16
        public var inputFormat: String
        public var frameCount: UInt64 = 0
        public var firstBufferOffset: TimeInterval
        public init(source: CaptureAudioSource, sampleRate: Double, channels: UInt32,
                    inputFormat: String, firstBufferOffset: TimeInterval) {
            self.source = source; self.sampleRate = sampleRate; self.channels = channels
            self.inputFormat = inputFormat; self.firstBufferOffset = firstBufferOffset
        }
    }
    public var version = 1
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var retention: CaptureAudioRetention
    public var expiresAt: Date?
    public var state: State = .recording
    /// Closed vocabulary only; never persist an NSError description with paths.
    public var failure: Failure?
    public enum Failure: String, Codable, Sendable { case storage, queueOverflow, upstreamGap, formatChanged, finalizationTimeout }
    public var sources: [Source] = []
    public init(id: UUID = UUID(), startedAt: Date, retention: CaptureAudioRetention) {
        self.id = id; self.startedAt = startedAt; self.retention = retention
        self.expiresAt = retention.expiration(from: startedAt)
    }
}

/// Synchronous disk operations: call off the UI/audio threads. The directory is
/// private to this profile and never scanned recursively. Incomplete/crash
/// leftovers remain inspectable; inspection never upgrades them to complete.
public final class CaptureAudioArchiveStore: @unchecked Sendable {
    public enum ArchiveError: Error, Sendable, Equatable { case retentionDisabled, unsafePath, invalidManifest, busy, io }
    public struct Entry: Sendable, Identifiable {
        public var id: UUID
        public var manifest: CaptureAudioManifest?
        public var isLeased: Bool
        /// Fixed-name files discovered independently of the last checkpoint;
        /// useful when a crash happened before metadata could be written.
        public var availableSources: [CaptureAudioSource]
        public var isInterrupted: Bool { manifest == nil || (manifest?.state == .recording && !isLeased) || manifest?.state == .interrupted }
    }
    public let root: URL
    private static let registry = Registry()
    private final class Registry: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var counts: [String: Int] = [:]
    }
    private static let knownFiles = Set(["manifest.json", "manifest.pending", "microphone.caf", "systemAudio.caf"])

    public init(profileDirectory: URL) {
        root = profileDirectory.appendingPathComponent("CaptureAudio", isDirectory: true).standardizedFileURL
    }
    private func key(_ id: UUID) -> String { root.path + "/" + id.uuidString }
    public func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// Retain this object for the entire read/export/retranscription operation.
    /// An active recording also holds a lease, including a quarantined writer.
    public final class Lease: @unchecked Sendable {
        public let id: UUID
        private let store: CaptureAudioArchiveStore
        fileprivate init(id: UUID, store: CaptureAudioArchiveStore) { self.id = id; self.store = store }
        public func audioURL(for source: CaptureAudioSource) throws -> URL {
            let folder = try store.checkedDirectory(id)
            let url = folder.appendingPathComponent(source.filename)
            try store.requireRegularFile(url)
            return url
        }
        deinit { store.release(id) }
    }
    public func acquireLease(_ id: UUID) throws -> Lease {
        Self.registry.lock.lock(); defer { Self.registry.lock.unlock() }
        _ = try checkedDirectory(id)
        Self.registry.counts[key(id), default: 0] += 1
        return Lease(id: id, store: self)
    }
    private func release(_ id: UUID) {
        Self.registry.lock.lock(); defer { Self.registry.lock.unlock() }
        let count = Self.registry.counts[key(id), default: 1] - 1
        Self.registry.counts[key(id)] = count > 0 ? count : nil
    }
    public func create(_ manifest: CaptureAudioManifest) throws -> Lease {
        guard manifest.retention != .discard else { throw ArchiveError.retentionDisabled }
        Self.registry.lock.lock(); defer { Self.registry.lock.unlock() }
        try ensureRoot()
        let folder = directory(for: manifest.id)
        guard mkdir(folder.path, 0o700) == 0 else { throw ArchiveError.io }
        try excludeFromBackup(folder)
        try writeManifest(manifest)
        return try acquireLease(manifest.id)
    }
    public func writeManifest(_ manifest: CaptureAudioManifest) throws {
        let folder = try checkedDirectory(manifest.id)
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ArchiveError.unsafePath }
        defer { close(fd) }
        // Remove only our fixed temporary name, never follow a link.
        _ = unlinkat(fd, "manifest.pending", 0)
        let output = openat(fd, "manifest.pending", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw ArchiveError.io }
        defer { close(output) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw ArchiveError.io }
                offset += count
            }
        }
        guard fsync(output) == 0, renameat(fd, "manifest.pending", fd, "manifest.json") == 0,
              fsync(fd) == 0 else { throw ArchiveError.io }
    }
    /// Reserves a private, non-symlink file before AVAudioFile opens it.
    public func reserveAudioFile(_ source: CaptureAudioSource, id: UUID) throws -> URL {
        let folder = try checkedDirectory(id)
        let url = folder.appendingPathComponent(source.filename)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ArchiveError.unsafePath }
        close(fd)
        try excludeFromBackup(url)
        return url
    }
    public func inspect(_ id: UUID) throws -> Entry {
        Self.registry.lock.lock(); defer { Self.registry.lock.unlock() }
        let folder = try checkedDirectory(id)
        let url = folder.appendingPathComponent("manifest.json")
        var manifest: CaptureAudioManifest?
        if let data = try? readSmallPrivateFile(url) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let value = try? decoder.decode(CaptureAudioManifest.self, from: data), value.id == id, value.version == 1 {
                manifest = value
            }
        }
        let availableSources = CaptureAudioSource.allCases.filter {
            (try? requireRegularFile(folder.appendingPathComponent($0.filename))) != nil
        }
        return Entry(id: id, manifest: manifest, isLeased: Self.registry.counts[key(id), default: 0] > 0,
                     availableSources: availableSources)
    }
    public func list() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try requireDirectory(root)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { url in
                guard let id = UUID(uuidString: url.lastPathComponent), id.uuidString == url.lastPathComponent else { return nil }
                return try? inspect(id)
            }.sorted { ($0.manifest?.startedAt ?? .distantPast) > ($1.manifest?.startedAt ?? .distantPast) }
    }
    /// Never recursively remove directories or unknown files. A malformed or
    /// unfamiliar archive is left untouched for inspection/manual recovery.
    public func delete(_ id: UUID) throws {
        Self.registry.lock.lock(); defer { Self.registry.lock.unlock() }
        guard Self.registry.counts[key(id), default: 0] == 0 else { throw ArchiveError.busy }
        let folder = try checkedDirectory(id)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for file in files {
            guard Self.knownFiles.contains(file.lastPathComponent) else { throw ArchiveError.unsafePath }
            try requireRegularFile(file)
        }
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ArchiveError.unsafePath }
        defer { close(fd) }
        for file in files { guard unlinkat(fd, file.lastPathComponent, 0) == 0 else { throw ArchiveError.io } }
        guard rmdir(folder.path) == 0 else { throw ArchiveError.io }
    }
    @discardableResult public func deleteExpired(now: Date = .now) throws -> [UUID] {
        var deleted: [UUID] = []
        for entry in try list() {
            guard !entry.isLeased, let manifest = entry.manifest,
                  manifest.retention == .sevenDays, let expiry = manifest.expiresAt,
                  expiry == manifest.retention.expiration(from: manifest.startedAt), expiry <= now else { continue }
            do { try delete(entry.id); deleted.append(entry.id) } catch { /* Preserve unsafe/busy leftovers. */ }
        }
        return deleted
    }
    /// Explicit user export only; creates a new UUID subfolder, never overwrites.
    /// Export is independent of managed retention and may outlive the archive.
    public func export(_ id: UUID, to destinationDirectory: URL) throws -> URL {
        // Also permit recovery exports of crash leftovers/corrupt manifests.
        // Do not snapshot a live writer (or disrupt an existing reader).
        Self.registry.lock.lock()
        let entry: Entry
        let lease: Lease
        do {
            entry = try inspect(id)
            guard !entry.isLeased else { throw ArchiveError.busy }
            lease = try acquireLease(id)
            Self.registry.lock.unlock()
        } catch { Self.registry.lock.unlock(); throw error }
        defer { withExtendedLifetime(lease) {} }
        let destination = destinationDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard mkdir(destination.path, 0o700) == 0 else { throw ArchiveError.io }
        for source in entry.availableSources {
            let input = try lease.audioURL(for: source)
            let output = destination.appendingPathComponent(source.filename)
            try copyPrivateFile(input, to: output)
        }
        let input = try checkedDirectory(id).appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: input.path) {
            try requireRegularFile(input)
            let output = destination.appendingPathComponent("manifest.json")
            try copyPrivateFile(input, to: output)
        }
        return destination
    }
    private func ensureRoot() throws {
        try requireDirectory(root.deletingLastPathComponent())
        if mkdir(root.path, 0o700) != 0, errno != EEXIST { throw ArchiveError.io }
        try requireDirectory(root)
        guard chmod(root.path, 0o700) == 0 else { throw ArchiveError.io }
        try excludeFromBackup(root)
    }
    private func checkedDirectory(_ id: UUID) throws -> URL {
        try requireDirectory(root)
        let folder = directory(for: id); try requireDirectory(folder); return folder
    }
    private func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw ArchiveError.unsafePath }
    }
    private func requireRegularFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw ArchiveError.unsafePath }
    }
    private func openPrivateFile(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ArchiveError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { close(fd); throw ArchiveError.unsafePath }
        return fd
    }
    private func readSmallPrivateFile(_ url: URL) throws -> Data {
        let fd = try openPrivateFile(url); defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_size <= 65_536 else { throw ArchiveError.invalidManifest }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw ArchiveError.io }
                offset += count
            }
        }
        return data
    }
    private func copyPrivateFile(_ input: URL, to output: URL) throws {
        let source = try openPrivateFile(input); defer { close(source) }
        let destination = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destination >= 0 else { throw ArchiveError.unsafePath }
        defer { close(destination) }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(source, &chunk, chunk.count)
            guard count >= 0 else { throw ArchiveError.io }
            if count == 0 { break }
            try chunk.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(destination, bytes.baseAddress!.advanced(by: offset), count - offset)
                    guard written > 0 else { throw ArchiveError.io }
                    offset += written
                }
            }
        }
        guard fsync(destination) == 0 else { throw ArchiveError.io }
    }
    private func excludeFromBackup(_ url: URL) throws {
        var url = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
