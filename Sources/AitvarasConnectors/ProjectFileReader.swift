import Foundation
import Darwin

/// A per-turn capability: immutable approved roots, pinned directory handles,
/// no path-based reopen, no symlink traversal, no shell, and no write API.
final class ProjectFileReader: @unchecked Sendable {
    struct Output: Sendable { let text: String; let path: String; let bytes: Int }
    enum Denied: Error { case access, limit, cancelled }
    static let maxFileBytes = 65_536
    static let maxTurnBytes = 524_288
    private let roots: [Int32]
    private let lock = NSLock()
    private var cancelled = false
    private var pending: Completion?
    private var calls = 0
    private var bytes = 0

    /// Setup owns its cancellation state independently of the client actor. Slow
    /// filesystem calls may finish later, but can never publish a late capability.
    final class Preparation: @unchecked Sendable {
        private let paths: [String]
        private let lock = NSLock()
        private var finished = false
        private var revoked = false
        private var continuation: CheckedContinuation<ProjectFileReader, Error>?
        init(roots: [String]) { paths = roots }
        func cancel() {
            lock.withLock { revoked = true }
            finish(.failure(Denied.cancelled))
        }
        func ensureActive() throws {
            if lock.withLock({ revoked }) { throw Denied.cancelled }
        }
        private var isFinished: Bool { lock.withLock { finished } }
        private func finish(_ result: Result<ProjectFileReader, Error>) {
            let waiting = lock.withLock {
                guard !finished else { return nil as CheckedContinuation<ProjectFileReader, Error>? }
                finished = true
                if case .failure = result { revoked = true }
                let waiting = continuation; continuation = nil; return waiting
            }
            // A late success is deliberately not retained: its pinned handles close.
            waiting?.resume(with: result)
        }
        func prepare() async throws -> ProjectFileReader {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiting in
                    let accepted = lock.withLock {
                        guard !finished, continuation == nil else { return false }
                        continuation = waiting; return true
                    }
                    guard accepted else { waiting.resume(throwing: Denied.cancelled); return }
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        finish(Result { try ProjectFileReader(roots: paths, isCancelled: { self.isFinished }) })
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                        finish(.failure(Denied.limit))
                    }
                }
            } onCancel: { self.cancel() }
        }
    }

    init(roots paths: [String], isCancelled: @Sendable () -> Bool = { false }) throws {
        guard paths.count <= 16, Set(paths).count == paths.count else { throw Denied.access }
        var opened: [Int32] = []
        do {
            for path in paths {
                guard !isCancelled() else { throw Denied.cancelled }
                let parts = try Self.components(path, absolute: true)
                let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
                guard parts.count >= 3, path != home, !home.hasPrefix(path + "/"),
                      !parts.contains(where: Self.forbidden), let resolved = realpath(path, nil) else { throw Denied.access }
                let canonical = String(cString: resolved); free(resolved)
                guard canonical == path else { throw Denied.access }
                var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard fd >= 0 else { throw Denied.access }
                do {
                    for part in parts {
                        guard !isCancelled() else { throw Denied.cancelled }
                        let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard next >= 0 else { throw Denied.access }
                        close(fd); fd = next
                    }
                    opened.append(fd)
                } catch { close(fd); throw error }
            }
            guard !isCancelled() else { throw Denied.cancelled }
            roots = opened
        } catch { opened.forEach { close($0) }; throw error }
    }
    deinit { roots.forEach { close($0) } }
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Output, Error>?
        init(_ continuation: CheckedContinuation<Output, Error>) { self.continuation = continuation }
        @discardableResult func finish(_ result: Result<Output, Error>) -> Bool {
            let value = lock.withLock { let value = continuation; continuation = nil; return value }
            value?.resume(with: result); return value != nil
        }
    }
    func cancel() {
        let completion = lock.withLock { cancelled = true; return pending }
        completion?.finish(.failure(Denied.cancelled))
    }
    /// Blocking filesystem I/O never occupies the client actor. A stopped or slow
    /// read loses its reply capability even if the filesystem has not returned yet.
    func executeAsync(tool: String, root: Int, path: String) async throws -> Output {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion = Completion(continuation)
                let accepted = lock.withLock {
                    guard !cancelled, pending == nil else { return false }
                    pending = completion; return true
                }
                guard accepted else { completion.finish(.failure(Denied.cancelled)); return }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let result = Result { try execute(tool: tool, root: root, path: path) }
                    lock.withLock { if pending === completion { pending = nil } }
                    completion.finish(result)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                    if completion.finish(.failure(Denied.limit)) { cancel() }
                }
            }
        } onCancel: { self.cancel() }
    }
    func ensureActive() throws { try check(ContinuousClock.now.advanced(by: .seconds(2))) }
    private func check(_ deadline: ContinuousClock.Instant) throws {
        if lock.withLock({ cancelled }) || Task.isCancelled { throw Denied.cancelled }
        if ContinuousClock.now >= deadline { throw Denied.limit }
    }
    static func forbidden(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix(".") || ["library", "keys", "secrets", "credentials", "node_modules"].contains(lower)
            || [".pem", ".key", ".p12", ".pfx", ".keystore"].contains(where: lower.hasSuffix)
            || ["secrets.", "credentials.", "auth.json"].contains(where: lower.hasPrefix)
            || lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ed25519")
    }
    private static func components(_ path: String, absolute: Bool) throws -> [String] {
        guard path.utf8.count <= 4096, !path.contains("\0"), !path.contains("\\"),
              path.hasPrefix("/") == absolute else { throw Denied.access }
        if path.isEmpty && !absolute { return [] }
        let value = absolute ? String(path.dropFirst()) : path
        let parts = value.components(separatedBy: "/")
        guard parts.count <= 64, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw Denied.access }
        return parts
    }
    func execute(tool: String, root: Int, path: String) throws -> Output {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        try check(deadline)
        guard ["aitvaras_project_list", "aitvaras_project_read"].contains(tool), roots.indices.contains(root) else { throw Denied.access }
        calls += 1; guard calls <= 32 else { throw Denied.limit }
        let parts = try Self.components(path, absolute: false)
        guard !parts.contains(where: Self.forbidden) else { throw Denied.access }
        let listing = tool == "aitvaras_project_list"
        guard listing || !parts.isEmpty else { throw Denied.access }
        var fd = dup(roots[root]); guard fd >= 0 else { throw Denied.access }
        defer { close(fd) }
        var rootMetadata = stat()
        guard fstat(fd, &rootMetadata) == 0 else { throw Denied.access }
        for (index, part) in parts.enumerated() {
            try check(deadline)
            let directory = listing || index < parts.count - 1
            let next = openat(fd, part, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
            guard next >= 0 else { throw Denied.access }
            close(fd); fd = next
            var componentMetadata = stat()
            guard fstat(fd, &componentMetadata) == 0, componentMetadata.st_dev == rootMetadata.st_dev else { throw Denied.access }
        }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw Denied.access }
        let text: String
        if listing {
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else { throw Denied.access }
            // A fresh open description keeps readdir's offset away from the pinned root.
            let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC); guard copy >= 0 else { throw Denied.access }
            guard let directory = fdopendir(copy) else { close(copy); throw Denied.access }
            defer { closedir(directory) }
            var names: [String] = [], scanned = 0
            while let entry = readdir(directory) {
                try check(deadline)
                scanned += 1; guard scanned <= 2048 else { throw Denied.limit }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard !Self.forbidden(name), (try? Self.components(name, absolute: false)) != nil else { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let kind = info.st_mode & S_IFMT
                guard kind == S_IFDIR || (kind == S_IFREG && info.st_nlink == 1) else { continue }
                names.append(name + (kind == S_IFDIR ? "/" : ""))
                guard names.count <= 200 else { throw Denied.limit }
            }
            text = names.sorted().joined(separator: "\n")
        } else {
            guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_nlink == 1,
                  metadata.st_size >= 0, metadata.st_size <= Self.maxFileBytes else { throw Denied.access }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                try check(deadline)
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; throw Denied.access }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= Self.maxFileBytes else { throw Denied.limit }
            }
            var after = stat()
            guard fstat(fd, &after) == 0, after.st_nlink == 1, after.st_size == metadata.st_size,
                  after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec,
                  !data.contains(0), let value = String(data: data, encoding: .utf8),
                  !value.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else { throw Denied.access }
            text = value
        }
        try check(deadline)
        bytes += text.utf8.count; guard bytes <= Self.maxTurnBytes else { throw Denied.limit }
        return Output(text: text, path: "project[\(root)]/\(path)", bytes: text.utf8.count)
    }
}
