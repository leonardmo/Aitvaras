import Foundation
import Darwin

/// Creates only private directories and links, without reading linked content
/// or opening credentials. Descriptor traversal rejects substituted directories.
public enum ClaudeProfileDirectory {
    public enum Failure: Error { case unsafeDirectory, creationFailed }
    public static let sharedNames = ["CLAUDE.md", "settings.json", "skills", "plugins"]

    public static func create(stateDirectory: URL, defaultDirectory: URL, id: UUID) throws -> URL {
        let state = try openDirectory(stateDirectory)
        defer { close(state) }
        var directory = dup(state)
        guard directory >= 0 else { throw Failure.creationFailed }
        defer { close(directory) }
        for name in ["Providers", "claude"] {
            if mkdirat(directory, name, 0o700) != 0 && errno != EEXIST { throw Failure.creationFailed }
            let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.unsafeDirectory }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                close(next); throw Failure.unsafeDirectory
            }
            close(directory); directory = next
        }
        let name = id.uuidString
        // Refuse reuse, including a symlink or another account's directory.
        guard mkdirat(directory, name, 0o700) == 0 else { throw Failure.creationFailed }
        let destination = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destination >= 0 else { throw Failure.unsafeDirectory }
        defer { close(destination) }
        let source: Int32
        do { source = try openDirectory(defaultDirectory) }
        catch {
            // A missing default CLI home is normal before the first login.
            if errno == ENOENT { return stateDirectory.appendingPathComponent("Providers/claude/" + name) }
            throw error
        }
        defer { close(source) }
        for entry in sharedNames {
            var info = stat()
            if fstatat(source, entry, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }; throw Failure.unsafeDirectory
            }
            // The target may itself be a user-managed symlink. We only create
            // a link to its name; never resolve, open or copy its contents.
            guard symlinkat(defaultDirectory.appendingPathComponent(entry).path, destination, entry) == 0 else { throw Failure.creationFailed }
        }
        return stateDirectory.appendingPathComponent("Providers/claude/" + name)
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw Failure.unsafeDirectory }
        // The caller supplies the trusted state/default root. Managed children
        // are opened relative to its descriptor; opening ancestors would add
        // unrelated filesystem authority and reject normal system path aliases.
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafeDirectory }
        return descriptor
    }
}
