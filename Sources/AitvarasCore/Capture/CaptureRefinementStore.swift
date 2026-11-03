import Foundation
import Darwin

/// Independent output records: deleting retained audio does not overwrite or
/// remove the original live transcript or an explicitly saved ASR candidate.
public struct CaptureRefinementStore: Sendable {
    public enum StoreError: Error, Sendable { case unsafePath, invalidRecord, io }
    public let root: URL
    public init(profileDirectory: URL) {
        root = profileDirectory.appendingPathComponent("CaptureRefinements", isDirectory: true)
    }
    public func url(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }

    @discardableResult public func save(_ candidate: CaptureRefinementCandidate) throws -> URL {
        try requireDirectory(root.deletingLastPathComponent())
        if mkdir(root.path, 0o700) != 0, errno != EEXIST { throw StoreError.io }
        try requireDirectory(root)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(candidate)
        let file = url(for: candidate.id)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StoreError.io }
        var succeeded = false
        defer { close(fd); if !succeeded { _ = unlink(file.path) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw StoreError.io }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw StoreError.io }
        let directoryFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw StoreError.unsafePath }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw StoreError.io }
        var folder = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        succeeded = true
        return file
    }

    public func load(_ id: UUID) throws -> CaptureRefinementCandidate {
        try requireDirectory(root)
        let file = url(for: id)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw StoreError.io }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 64 * 1024 * 1024 else { throw StoreError.unsafePath }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw StoreError.io }; offset += count
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let candidate = try decoder.decode(CaptureRefinementCandidate.self, from: data)
        guard candidate.id == id, candidate.segments.allSatisfy({
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
        }) else { throw StoreError.invalidRecord }
        return candidate
    }

    public func list(archiveID: UUID) throws -> [CaptureRefinementCandidate] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try requireDirectory(root)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { file -> CaptureRefinementCandidate? in
                guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      let candidate = try? load(id), candidate.archiveID == archiveID else { return nil }
                return candidate
            }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Explicit deletion of this archive's own, valid candidate records only.
    /// Unknown files, malformed records and unrelated archives are preserved.
    public func delete(archiveID: UUID) throws {
        for candidate in try list(archiveID: archiveID) {
            let file = url(for: candidate.id)
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1 else { throw StoreError.unsafePath }
            guard unlink(file.path) == 0 else { throw StoreError.io }
        }
    }

    private func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw StoreError.unsafePath }
    }
}
