import Darwin
import Foundation

/// A per-process callback endpoint for an app-registered provider helper.
/// Authorizing actions remains the caller's responsibility.
public actor ProviderHookSocket {
    public nonisolated let url: URL
    private let directory: URL
    private let listener: GatewayUnixListener
    private var accepting: Task<Void, Never>?
    private var closed = false
    private var peers: [UUID: (GatewayFDChannel, Task<Void, Never>)] = [:]

    public init() throws {
        // Unix sockets need a short pathname independent of the state profile.
        var template = Array("/tmp/aitvaras-hook.XXXXXX".utf8CString)
        guard let directory = template.withUnsafeMutableBufferPointer({ buffer in
            mkdtemp(buffer.baseAddress!).map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) }
        }) else { throw GatewayTransportError.system("create provider callback directory", errno) }
        let url = directory.appendingPathComponent("hook.sock")
        do { listener = try GatewayUnixListener(socketURL: url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        self.directory = directory
        self.url = url
    }

    deinit {
        listener.stop()
        accepting?.cancel()
        for (channel, task) in peers.values { channel.stop(); task.cancel() }
        try? FileManager.default.removeItem(at: directory)
    }

    public func bind(ownerPID: pid_t, verifyPeer: @escaping @Sendable (GatewaySocketPeer) -> Bool = { _ in true },
                     handler: @escaping @Sendable (JSONValue) async -> JSONValue?) throws {
        guard !closed, accepting == nil else { throw AgentFailure.invalidTransition }
        let inspector = GatewayProcessInspector.live
        let root = try inspector.snapshot(ownerPID).identity
        accepting = Task { [weak self, listener] in
            while !Task.isCancelled {
                guard let channel = try? await listener.acceptChannel(), !Task.isCancelled else { return }
                await self?.accept(channel, root: root, inspector: inspector, verifyPeer: verifyPeer, handler: handler)
            }
        }
    }

    public func close() {
        closed = true
        listener.stop()
        accepting?.cancel()
        accepting = nil
        for (channel, task) in peers.values { channel.stop(); task.cancel() }
        peers.removeAll()
    }

    private func accept(_ channel: GatewayFDChannel, root: GatewayProcessIdentity, inspector: GatewayProcessInspector,
                        verifyPeer: @escaping @Sendable (GatewaySocketPeer) -> Bool,
                        handler: @escaping @Sendable (JSONValue) async -> JSONValue?) {
        guard !closed, peers.count < 16 else { channel.stop(); return }
        let id = UUID()
        let task = Task { [weak self] in
            await Self.serve(channel, root: root, inspector: inspector, verifyPeer: verifyPeer, handler: handler)
            channel.stop()
            await self?.remove(id)
        }
        peers[id] = (channel, task)
    }

    private func remove(_ id: UUID) { peers[id] = nil }

    private static func serve(_ channel: GatewayFDChannel, root: GatewayProcessIdentity, inspector: GatewayProcessInspector,
                              verifyPeer: @escaping @Sendable (GatewaySocketPeer) -> Bool,
                              handler: @escaping @Sendable (JSONValue) async -> JSONValue?) async {
        do {
            let peer = try inspector.socketPeer(channel.socketFD)
            guard verifyPeer(peer), try inspector.nearestAncestor(of: peer.identity, matching: { $0 == root }) != nil,
                  let frame = try await channel.readFrame(until: .now.advanced(by: .seconds(5))),
                  let value = JSONValue.parse(String(decoding: frame, as: UTF8.self)),
                  value.objectValue != nil else { return }
            try Task.checkCancellation()
            guard let reply = await handler(value) else { return }
            try Task.checkCancellation()
            try await channel.writeFrame(Data(reply.jsonString.utf8), until: .now.advanced(by: .seconds(5)))
        } catch { /* The helper fails closed when no verdict is returned. */ }
    }

    /// Read the native hook's single JSON value from stdin without printing it.
    /// The socket carries the response selected by the owning app process.
    public static func relay(socketPath: String) async throws {
        var data = Data()
        let maximum = GatewayFrameDecoder.maximumBytes
        while let chunk = try FileHandle.standardInput.read(upToCount: min(4_096, maximum - data.count + 1)), !chunk.isEmpty {
            guard data.count + chunk.count <= maximum else { throw GatewayTransportError.frameTooLarge }
            data.append(chunk)
        }
        guard let request = JSONValue.parse(String(decoding: data, as: UTF8.self)),
              request.objectValue != nil else { throw GatewayTransportError.invalidFrame }
        let response = try await exchange(socketPath: socketPath, request: request)
        try FileHandle.standardOutput.write(contentsOf: Data(response.jsonString.utf8))
    }

    public static func exchange(socketPath: String, request: JSONValue) async throws -> JSONValue {
        let components = socketPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4, components[0].isEmpty, components[1] == "tmp",
              components[2].hasPrefix("aitvaras-hook."), components[2].count == "aitvaras-hook.".count + 6,
              components[2].suffix(6).utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              components[3] == "hook.sock" else {
            throw GatewayTransportError.insecurePath
        }
        let channel = try GatewayUnixSocket.connect(socketURL: URL(fileURLWithPath: socketPath),
            until: .now.advanced(by: .seconds(5)))
        defer { channel.stop() }
        try await channel.writeFrame(Data(request.jsonString.utf8), until: .now.advanced(by: .seconds(5)))
        guard let frame = try await channel.readFrame(),
              let response = JSONValue.parse(String(decoding: frame, as: UTF8.self)) else { throw GatewayTransportError.closed }
        return response
    }
}
