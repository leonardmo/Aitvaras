import Darwin
import Foundation
import AitvarasCore

public enum GatewayTransportError: Error, LocalizedError, Equatable, Sendable {
    case system(String, Int32), insecurePath, pathTooLong, alreadyRunning
    case invalidFrame, frameTooLarge, timeout, closed, rejected, profileMismatch, appNotReady, missingBundle, untrustedBinary

    public var errorDescription: String? {
        switch self {
        case .system(let action, let code): "Gateway \(action) failed (errno \(code))."
        case .insecurePath: "The gateway path is not a private, owned socket location."
        case .pathTooLong: "The state directory is too long for a Unix socket."
        case .alreadyRunning: "A gateway already owns this state profile."
        case .invalidFrame: "Invalid gateway frame."
        case .frameTooLarge: "Gateway frame exceeds the size limit."
        case .timeout: "Gateway communication timed out."
        case .closed: "The gateway connection closed."
        case .rejected: "Aitvaras rejected this launch or MCP connection."
        case .profileMismatch: "The connected app is using a different Aitvaras profile."
        case .appNotReady: "Aitvaras did not open a gateway for the requested profile within 10 seconds."
        case .missingBundle: "Start the gateway command from an Aitvaras app bundle."
        case .untrustedBinary: "The gateway requires a valid signature for the bundled executable."
        }
    }
}

public struct GatewayEndpoint: Sendable, Equatable {
    public let stateDirectory: URL
    public let socketURL: URL
    public let profile: String

    public init(stateDirectory: URL = AitvarasPaths.stateDirectory) {
        socketURL = AitvarasPaths.gatewaySocketURL(stateDirectory: stateDirectory)
        self.stateDirectory = socketURL.deletingLastPathComponent().deletingLastPathComponent()
        profile = StableIdentifier.digest([self.stateDirectory.path])
    }
}

public struct GatewayFrameDecoder: Sendable {
    public static let maximumBytes = 256 * 1024
    private var pending = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        var frames: [Data] = []
        var start = bytes.startIndex
        while start != bytes.endIndex {
            let newline = bytes[start...].firstIndex(of: 10)
            let end = newline ?? bytes.endIndex
            guard pending.count + bytes.distance(from: start, to: end) <= Self.maximumBytes else {
                throw GatewayTransportError.frameTooLarge
            }
            pending.append(contentsOf: bytes[start..<end])
            guard newline != nil else { break }
            if pending.last == 13 { pending.removeLast() }
            guard !pending.isEmpty else { throw GatewayTransportError.invalidFrame }
            frames.append(pending)
            pending.removeAll(keepingCapacity: true)
            start = bytes.index(after: end)
        }
        return frames
    }

    public func finish() throws {
        guard pending.isEmpty else { throw GatewayTransportError.invalidFrame }
    }
}

public protocol GatewayFrameChannel: Sendable {
    func readFrame(until deadline: ContinuousClock.Instant?) async throws -> Data?
    func writeFrame(_ frame: Data, until deadline: ContinuousClock.Instant?) async throws
    func stop()
}

/// One reader and serialized writes. The descriptor stays owned until the
/// last I/O closure finishes. stop wakes socket I/O without reusing the fd.
public final class GatewayFDChannel: GatewayFrameChannel, @unchecked Sendable {
    private let input: Int32
    private let output: Int32
    private let socket: Bool
    private let readQueue = DispatchQueue(label: "aitvaras.gateway.read")
    private let writeQueue = DispatchQueue(label: "aitvaras.gateway.write")
    private let lock = NSLock()
    private var stopped = false
    // Access confined to readQueue.
    private var decoder = GatewayFrameDecoder()
    private var frames: [Data] = []

    init(socket fd: Int32) {
        input = fd; output = fd; socket = true
    }

    public static func standardIO() throws -> GatewayFDChannel {
        let input = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 0)
        guard input >= 0 else { throw GatewayTransportError.system("duplicate stdin", errno) }
        let output = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 0)
        guard output >= 0 else {
            let code = errno
            close(input)
            throw GatewayTransportError.system("duplicate stdout", code)
        }
        return .init(input: input, output: output)
    }

    private init(input: Int32, output: Int32) {
        self.input = input; self.output = output; socket = false
    }

    deinit {
        close(input)
        if output != input { close(output) }
    }

    var socketFD: Int32 { input }

    public func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            if socket { _ = shutdown(input, SHUT_RDWR) }
        }
    }

    public func readFrame(until deadline: ContinuousClock.Instant? = nil) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async { [self] in
                continuation.resume(with: Result { try readNext(until: deadline) })
            }
        }
    }

    public func writeFrame(_ frame: Data, until deadline: ContinuousClock.Instant? = nil) async throws {
        guard !frame.isEmpty, !frame.contains(10), !frame.contains(13) else { throw GatewayTransportError.invalidFrame }
        guard frame.count <= GatewayFrameDecoder.maximumBytes else { throw GatewayTransportError.frameTooLarge }
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async { [self] in
                continuation.resume(with: Result {
                    var data = frame
                    data.append(10)
                    try data.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            try wait(output, events: Int16(POLLOUT), until: deadline)
                            let chunk = min(bytes.count - offset, socket ? 4096 : Int(PIPE_BUF))
                            let n = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), chunk)
                            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                            guard n > 0 else { throw GatewayTransportError.system("write", errno) }
                            offset += n
                        }
                    }
                })
            }
        }
    }

    private func readNext(until deadline: ContinuousClock.Instant?) throws -> Data? {
        guard !lock.withLock({ stopped }) else { throw GatewayTransportError.closed }
        if !frames.isEmpty { return frames.removeFirst() }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(input, events: Int16(POLLIN), until: deadline)
            let n = Darwin.read(input, &chunk, chunk.count)
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard n >= 0 else { throw GatewayTransportError.system("read", errno) }
            if n == 0 { try decoder.finish(); return nil }
            frames = try decoder.append(Data(chunk.prefix(n)))
            if !frames.isEmpty { return frames.removeFirst() }
        }
    }

    private func wait(_ fd: Int32, events: Int16, until deadline: ContinuousClock.Instant?) throws {
        while true {
            guard !lock.withLock({ stopped }) else { throw GatewayTransportError.closed }
            let timeout = try gatewayPollTimeout(deadline)
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&descriptor, 1, timeout)
            if ready > 0 { return }
            if ready < 0 && errno != EINTR { throw GatewayTransportError.system("poll", errno) }
        }
    }
}

func gatewayPollTimeout(_ deadline: ContinuousClock.Instant?) throws -> Int32 {
    guard let deadline else { return 100 }
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else { throw GatewayTransportError.timeout }
    guard remaining < .milliseconds(100) else { return 100 }
    return Int32(max(1, remaining.components.attoseconds / 1_000_000_000_000_000))
}
