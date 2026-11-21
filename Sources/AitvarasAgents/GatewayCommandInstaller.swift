import Darwin
import Foundation

public struct GatewayCommandInstaller: Sendable {
    public enum Status: Equatable, Sendable { case absent, installed, occupied }
    public enum Failure: LocalizedError, Equatable, Sendable {
        case occupied, missingLauncher, unsafeDirectory, filesystem

        public var errorDescription: String? {
            switch self {
            case .occupied: "The command path is already in use."
            case .missingLauncher: "The bundled launcher is unavailable."
            case .unsafeDirectory: "The user bin folder could not be opened safely."
            case .filesystem: "The command link could not be changed."
            }
        }
    }

    private let home: URL
    private let launcher: URL
    public var bin: URL { home.appendingPathComponent(".local/bin", isDirectory: true) }
    public var command: URL { bin.appendingPathComponent("aitvaras") }

    public init(home: URL, launcher: URL) {
        self.home = home.standardizedFileURL
        self.launcher = launcher.standardizedFileURL
    }

    public func onPath(_ path: String) -> Bool {
        let expected = bin.resolvingSymlinksInPath().path
        return path.split(separator: ":").contains { entry in
            entry.hasPrefix("/") && URL(fileURLWithPath: String(entry)).resolvingSymlinksInPath().path == expected
        }
    }

    public func status() throws -> Status {
        try withBin(create: false) { try inspect($0) } ?? .absent
    }

    public func install() throws {
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else { throw Failure.missingLauncher }
        _ = try withBin(create: true) { fd in
            if symlinkat(launcher.path, fd, "aitvaras") == 0 { return }
            guard errno == EEXIST else { throw Failure.filesystem }
            guard try inspect(fd) == .installed else { throw Failure.occupied }
        }
    }

    public func uninstall() throws {
        _ = try withBin(create: false) { fd in
            switch try inspect(fd) {
            case .absent: return
            case .occupied: throw Failure.occupied
            case .installed:
                guard unlinkat(fd, "aitvaras", 0) == 0 else { throw Failure.filesystem }
            }
        }
    }

    private func inspect(_ fd: Int32) throws -> Status {
        var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let count = bytes.withUnsafeMutableBytes { buffer in
            readlinkat(fd, "aitvaras", buffer.baseAddress!.assumingMemoryBound(to: CChar.self), buffer.count)
        }
        if count < 0 {
            if errno == ENOENT { return .absent }
            if errno == EINVAL { return .occupied }
            throw Failure.filesystem
        }
        return bytes.prefix(count).elementsEqual(launcher.path.utf8) ? .installed : .occupied
    }

    private func withBin<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T? {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var directory = open(home.resolvingSymlinksInPath().path, flags)
        guard directory >= 0 else { throw Failure.unsafeDirectory }
        defer { close(directory) }
        for part in [".local", "bin"] {
            if create, mkdirat(directory, part, 0o700) != 0, errno != EEXIST { throw Failure.unsafeDirectory }
            let next = openat(directory, part, flags)
            if next < 0, errno == ENOENT, !create { return nil }
            guard next >= 0 else { throw Failure.unsafeDirectory }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
                close(next)
                throw Failure.unsafeDirectory
            }
            close(directory)
            directory = next
        }
        return try body(directory)
    }
}
