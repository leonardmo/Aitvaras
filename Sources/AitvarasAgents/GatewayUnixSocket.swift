import Darwin
import Foundation

enum GatewayUnixSocket {
    static func connect(_ endpoint: GatewayEndpoint, until deadline: ContinuousClock.Instant) throws -> GatewayFDChannel {
        let path = endpoint.socketURL.path
        // Validate the length even when the app has not created the directory.
        _ = try address(path)
        let directory = try statAt(endpoint.socketURL.deletingLastPathComponent().path)
        guard type(directory) == S_IFDIR, directory.st_uid == geteuid(), directory.st_mode & 0o777 == 0o700 else {
            throw GatewayTransportError.insecurePath
        }
        let node = try statAt(path)
        guard type(node) == S_IFSOCK, node.st_uid == geteuid(), node.st_mode & 0o777 == 0o600 else {
            throw GatewayTransportError.insecurePath
        }
        return GatewayFDChannel(socket: try dial(path, until: deadline))
    }

    static func dial(_ path: String, until deadline: ContinuousClock.Instant) throws -> Int32 {
        let fd = try newSocket()
        do {
            let result = try withAddress(path) { Darwin.connect(fd, $0, $1) }
            if result < 0 {
                let code = errno
                guard code == EINPROGRESS || code == EINTR else { throw GatewayTransportError.system("connect", code) }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                while true {
                    let ready = poll(&descriptor, 1, try gatewayPollTimeout(deadline))
                    if ready > 0 { break }
                    if ready < 0 && errno != EINTR { throw GatewayTransportError.system("connect", errno) }
                }
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else {
                    throw GatewayTransportError.system("SO_ERROR", errno)
                }
                guard error == 0 else { throw GatewayTransportError.system("connect", error) }
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func newSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GatewayTransportError.system("socket(AF_UNIX)", errno) }
        do { try configure(fd); return fd }
        catch { close(fd); throw error }
    }

    static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) >= 0, fcntl(fd, F_SETFL, O_NONBLOCK) >= 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) >= 0 else { throw GatewayTransportError.system("configure socket", errno) }
    }

    static func address(_ path: String) throws -> (sockaddr_un, socklen_t) {
        var address = sockaddr_un()
        let bytes = path.utf8CString
        guard !path.contains("\0"), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw GatewayTransportError.pathTooLong
        }
        let length = 2 + bytes.count   // Darwin's sun_len and one-byte sun_family.
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        return (address, socklen_t(length))
    }

    static func withAddress<Result>(_ path: String, run: (UnsafePointer<sockaddr>, socklen_t) -> Result) throws -> Result {
        var (address, length) = try address(path)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { run($0, length) }
        }
    }

    static func statAt(_ path: String, directory: Int32 = AT_FDCWD) throws -> stat {
        var info = stat()
        guard fstatat(directory, path, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw GatewayTransportError.system("inspect socket path", errno)
        }
        return info
    }

    static func type(_ info: stat) -> mode_t { info.st_mode & S_IFMT }
    static func same(_ lhs: stat, _ rhs: stat) -> Bool { lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino }
}

final class GatewayUnixListener: @unchecked Sendable {
    private let fd: Int32
    private let directory: Int32
    private let ownerLock: Int32
    private let name: String
    private let inode: stat
    private let queue = DispatchQueue(label: "aitvaras.gateway.accept")
    private let state = NSLock()
    private var stopped = false

    init(_ endpoint: GatewayEndpoint) throws {
        let path = endpoint.socketURL.path
        _ = try GatewayUnixSocket.address(path)
        let folder = endpoint.socketURL.deletingLastPathComponent()
        let name = endpoint.socketURL.lastPathComponent
        if mkdir(folder.path, 0o700) != 0 && errno != EEXIST {
            throw GatewayTransportError.system("create socket directory", errno)
        }
        let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw GatewayTransportError.system("open socket directory", errno) }
        var lockFD: Int32 = -1, listenFD: Int32 = -1
        var owned: stat?
        var committed = false
        defer {
            if !committed {
                if let owned { Self.remove(name, directory: directory, ifSame: owned) }
                if listenFD >= 0 { close(listenFD) }
                if lockFD >= 0 { close(lockFD) }
                close(directory)
            }
        }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw GatewayTransportError.insecurePath
        }
        lockFD = openat(directory, "listener.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lockFD >= 0, fstat(lockFD, &info) == 0, GatewayUnixSocket.type(info) == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600 else { throw GatewayTransportError.insecurePath }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw GatewayTransportError.alreadyRunning }
            throw GatewayTransportError.system("lock socket directory", errno)
        }
        try Self.clearStale(path, name: name, directory: directory)

        listenFD = try GatewayUnixSocket.newSocket()
        guard try GatewayUnixSocket.withAddress(path, run: { bind(listenFD, $0, $1) }) == 0 else {
            throw GatewayTransportError.system("bind(AF_UNIX)", errno)
        }
        let created = try GatewayUnixSocket.statAt(name, directory: directory)
        guard GatewayUnixSocket.type(created) == S_IFSOCK, created.st_uid == geteuid() else {
            throw GatewayTransportError.insecurePath
        }
        owned = created
        guard fchmodat(directory, name, 0o600, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw GatewayTransportError.system("chmod socket", errno)
        }
        let secured = try GatewayUnixSocket.statAt(name, directory: directory)
        guard GatewayUnixSocket.same(created, secured), secured.st_mode & 0o777 == 0o600 else {
            throw GatewayTransportError.insecurePath
        }
        guard listen(listenFD, 16) == 0 else { throw GatewayTransportError.system("listen(AF_UNIX)", errno) }
        self.fd = listenFD
        self.ownerLock = lockFD
        self.directory = directory
        self.name = name
        self.inode = secured
        committed = true
    }

    deinit {
        stop()
        close(fd)
        close(ownerLock)
        close(directory)
    }

    func stop() {
        state.withLock {
            guard !stopped else { return }
            stopped = true
            _ = shutdown(fd, SHUT_RDWR)
            Self.remove(name, directory: directory, ifSame: inode)
        }
    }

    func acceptChannel() async throws -> GatewayFDChannel {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result {
                    while !state.withLock({ stopped }) {
                        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        let ready = poll(&descriptor, 1, 100)
                        if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                        guard ready > 0 else { throw GatewayTransportError.system("poll listener", errno) }
                        let peer = accept(fd, nil, nil)
                        if peer < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                        guard peer >= 0 else { throw GatewayTransportError.system("accept(AF_UNIX)", errno) }
                        do {
                            try GatewayUnixSocket.configure(peer)
                            return GatewayFDChannel(socket: peer)
                        } catch {
                            close(peer)
                            throw error
                        }
                    }
                    throw GatewayTransportError.closed
                })
            }
        }
    }

    private static func clearStale(_ path: String, name: String, directory: Int32) throws {
        let before: stat
        do { before = try GatewayUnixSocket.statAt(name, directory: directory) }
        catch GatewayTransportError.system(_, ENOENT) { return }
        guard GatewayUnixSocket.type(before) == S_IFSOCK, before.st_uid == geteuid(), before.st_nlink == 1 else {
            throw GatewayTransportError.insecurePath
        }
        do {
            let peer = try GatewayUnixSocket.dial(path, until: .now.advanced(by: .milliseconds(250)))
            close(peer)
            throw GatewayTransportError.alreadyRunning
        } catch GatewayTransportError.system("connect", ECONNREFUSED) {
            let after = try GatewayUnixSocket.statAt(name, directory: directory)
            guard GatewayUnixSocket.same(before, after), GatewayUnixSocket.type(after) == S_IFSOCK else {
                throw GatewayTransportError.insecurePath
            }
            guard unlinkat(directory, name, 0) == 0 else { throw GatewayTransportError.system("remove stale socket", errno) }
        }
    }

    private static func remove(_ name: String, directory: Int32, ifSame expected: stat) {
        guard let actual = try? GatewayUnixSocket.statAt(name, directory: directory),
              GatewayUnixSocket.type(actual) == S_IFSOCK, GatewayUnixSocket.same(actual, expected) else { return }
        _ = unlinkat(directory, name, 0)
    }
}
