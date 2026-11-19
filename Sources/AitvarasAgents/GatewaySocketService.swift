import Foundation

public enum GatewayHandshakeRole: Sendable, Equatable {
    case relay
    case register(GatewayLaunchContext.Client)
}

struct GatewayHandshake: Codable, Sendable {
    let version: Int
    let profile: String
    let role: String
    let client: GatewayLaunchContext.Client?

    init(endpoint: GatewayEndpoint, role: GatewayHandshakeRole) {
        version = 1
        profile = endpoint.profile
        switch role {
        case .relay: self.role = "relay"; client = nil
        case .register(let client): self.role = "register"; self.client = client
        }
    }

    var request: GatewayHandshakeRole? {
        switch (version, role, client) {
        case (1, "relay", nil): .relay
        case (1, "register", let client?): .register(client)
        default: nil
        }
    }
}

struct GatewayHandshakeReply: Codable, Sendable {
    enum Status: String, Codable, Sendable { case ready, rejected, wrongProfile }
    let version = 1
    let profile: String
    let status: Status

    enum CodingKeys: String, CodingKey { case version, profile, status }

    init(profile: String, status: Status) {
        self.profile = profile
        self.status = status
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == version else { throw GatewayTransportError.invalidFrame }
        profile = try c.decode(String.self, forKey: .profile)
        status = try c.decode(Status.self, forKey: .status)
    }
}

/// Converts Unix socket connections into verified launcher registrations or
/// MCP sessions. The injected verifier is the app's bundled-code check.
public actor GatewaySocketService {
    public typealias ResolveContext = @Sendable (GatewaySocketPeer, GatewayLaunchContext.Client) throws -> GatewayLaunchContext
    public typealias MakeSession = @Sendable (MCPGatewayInvocation, @escaping MCPGateway.Authorize) -> MCPGateway

    private let endpoint: GatewayEndpoint
    private let registry: GatewayLaunchRegistry
    private let verifyLauncher: @Sendable (GatewaySocketPeer) throws -> Bool
    private let resolveContext: ResolveContext
    private let makeSession: MakeSession
    private var listener: GatewayUnixListener?
    private var acceptTask: Task<Void, Never>?
    private struct Client {
        let channel: GatewayFDChannel
        let task: Task<Void, Never>
    }
    private var clients: [UUID: Client] = [:]

    public init(endpoint: GatewayEndpoint, registry: GatewayLaunchRegistry = .init(),
                verifyLauncher: @escaping @Sendable (GatewaySocketPeer) throws -> Bool,
                resolveContext: @escaping ResolveContext,
                makeSession: @escaping MakeSession) {
        self.endpoint = endpoint
        self.registry = registry
        self.verifyLauncher = verifyLauncher
        self.resolveContext = resolveContext
        self.makeSession = makeSession
    }

    deinit {
        listener?.stop()
        acceptTask?.cancel()
        for client in clients.values { client.channel.stop(); client.task.cancel() }
    }

    public func start() throws {
        guard listener == nil else { throw GatewayTransportError.alreadyRunning }
        let listener = try GatewayUnixListener(endpoint)
        self.listener = listener
        acceptTask = Task { [weak self, listener] in
            while !Task.isCancelled {
                guard let channel = try? await listener.acceptChannel(), !Task.isCancelled else { break }
                await self?.accept(channel, listener: listener)
            }
            await self?.acceptFinished(listener)
        }
    }

    public func stop() async {
        listener?.stop()
        listener = nil
        let task = acceptTask
        acceptTask = nil
        task?.cancel()
        let closing = Array(clients.values)
        for client in closing { client.channel.stop(); client.task.cancel() }
        await task?.value
        for client in closing { await client.task.value }
    }

    private func acceptFinished(_ finished: GatewayUnixListener) {
        guard listener === finished else { return }
        finished.stop()
        listener = nil
        acceptTask = nil
    }

    private func accept(_ channel: GatewayFDChannel, listener owner: GatewayUnixListener) {
        guard listener === owner, clients.count < 32 else { channel.stop(); return }
        let id = UUID()
        let endpoint = endpoint, registry = registry, verify = verifyLauncher, resolve = resolveContext, session = makeSession
        let task = Task { [weak self] in
            await Self.serve(channel, endpoint: endpoint, registry: registry, verify: verify, resolve: resolve, makeSession: session)
            channel.stop()
            await self?.remove(id)
        }
        clients[id] = Client(channel: channel, task: task)
    }

    private func remove(_ id: UUID) { clients.removeValue(forKey: id) }

    private static func serve(_ channel: GatewayFDChannel, endpoint: GatewayEndpoint, registry: GatewayLaunchRegistry,
                              verify: @Sendable (GatewaySocketPeer) throws -> Bool,
                              resolve: ResolveContext, makeSession: MakeSession) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        func reply(_ status: GatewayHandshakeReply.Status) async throws {
            let frame = try JSONEncoder().encode(GatewayHandshakeReply(profile: endpoint.profile, status: status))
            try await channel.writeFrame(frame, until: deadline)
        }
        do {
            guard let frame = try await channel.readFrame(until: deadline), frame.count <= 1_024,
                  let hello = try? JSONDecoder().decode(GatewayHandshake.self, from: frame),
                  let role = hello.request else { try await reply(.rejected); return }
            guard hello.profile == endpoint.profile else { try await reply(.wrongProfile); return }
            switch role {
            case .register(let client):
                _ = try await registry.registerLauncher(on: channel.socketFD, client: client, verifyLauncher: verify, resolveContext: resolve)
                try await reply(.ready)
            case .relay:
                let connection = try await registry.connect(on: channel.socketFD)
                do {
                    try await reply(.ready)
                    let invocation = MCPGatewayInvocation(launchID: connection.launch.id, context: connection.launch.context,
                                                          presentation: .outside)
                    let gateway = makeSession(invocation) { _ = try await registry.validate(connection) }
                    await bridge(channel, gateway: gateway, connection: connection)
                } catch {
                    channel.stop()
                }
                await registry.disconnect(connection)
            }
        } catch {
            try? await reply(.rejected)
        }
    }

    private static func bridge(_ channel: GatewayFDChannel, gateway: MCPGateway,
                               connection: GatewayLaunchRegistry.Connection) async {
        let requests = GatewaySocketRequests(channel: channel, gateway: gateway)
        let notifications = Task {
            for await frame in gateway.notifications {
                do { try await channel.writeFrame(frame, until: .now.advanced(by: .seconds(5))) }
                catch { channel.stop(); return }
            }
        }
        let invalidation = Task {
            for await _ in connection.invalidations {
                channel.stop()
                await gateway.close()
                return
            }
        }
        do {
            while let frame = try await channel.readFrame(until: nil) {
                try await requests.add(frame)
            }
        } catch { /* The peer closes on malformed or stalled I/O. */ }
        channel.stop()
        await gateway.close()
        await requests.cancel()
        notifications.cancel()
        invalidation.cancel()
        await notifications.value
        await invalidation.value
    }
}

private actor GatewaySocketRequests {
    let channel: GatewayFDChannel
    let gateway: MCPGateway
    var pending: [UUID: Task<Void, Never>] = [:]

    init(channel: GatewayFDChannel, gateway: MCPGateway) {
        self.channel = channel
        self.gateway = gateway
    }

    func add(_ frame: Data) async throws {
        guard pending.count < 40 else { throw GatewayTransportError.rejected }
        let id = UUID()
        let channel = channel, gateway = gateway
        let response = await gateway.beginFrame(frame)
        pending[id] = Task { [weak self] in
            let reply = await withTaskCancellationHandler { await response.value } onCancel: { response.cancel() }
            if let reply {
                do { try await channel.writeFrame(reply, until: .now.advanced(by: .seconds(5))) }
                catch { channel.stop() }
            }
            await self?.finished(id)
        }
    }

    func cancel() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    private func finished(_ id: UUID) { pending.removeValue(forKey: id) }
}
