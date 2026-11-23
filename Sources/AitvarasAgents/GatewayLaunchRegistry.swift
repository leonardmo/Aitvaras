import Darwin
import Dispatch
import Foundation

public struct GatewayLaunchContext: Equatable, Sendable {
    public enum Client: String, Codable, Sendable { case claude, codex }

    public let client: Client
    public let projectID: UUID?
    public let permissions: AgentChatPermissions?

    public init(client: Client, projectID: UUID?, permissions: AgentChatPermissions? = nil) {
        self.client = client
        self.projectID = projectID
        self.permissions = permissions
    }
}

public struct GatewayLaunch: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let root: GatewayProcessIdentity
    public let context: GatewayLaunchContext
    let chatID: UUID?
}

public enum GatewayLaunchRegistryError: Error, Equatable, Sendable {
    case unauthorized
    case alreadyRegistered
    case closed
}

/// One in-memory registry per profile. The listener owns socket and request
/// lifetimes and must stop pending work when the connection is invalidated.
public actor GatewayLaunchRegistry {
    public enum Invalidation: Equatable, Sendable {
        case revoked, launchExited, identityLost
    }

    public struct Connection: Sendable {
        public let launch: GatewayLaunch
        /// A single consumer can await the reason and cancel outstanding work.
        public let invalidations: AsyncStream<Invalidation>
        fileprivate let id: UUID
    }

    typealias WatchExit = @Sendable (pid_t, @escaping @Sendable () -> Void) -> (@Sendable () -> Void)

    private struct Entry {
        let launch: GatewayLaunch
        let stopWatching: @Sendable () -> Void
        var revoked = false
        var connections: Set<UUID> = []
    }

    private struct PeerConnection {
        let root: GatewayProcessIdentity
        let peer: GatewayProcessIdentity
        let invalidation: AsyncStream<Invalidation>.Continuation
    }

    private let inspector: GatewayProcessInspector
    private let watchExit: WatchExit
    private var entries: [GatewayProcessIdentity: Entry] = [:]
    private var connections: [UUID: PeerConnection] = [:]
    private var closed = false

    public init() {
        inspector = .live
        watchExit = Self.watchProcess
    }

    init(inspector: GatewayProcessInspector, watchExit: @escaping WatchExit) {
        self.inspector = inspector
        self.watchExit = watchExit
    }

    deinit {
        for entry in entries.values { entry.stopWatching() }
        for connection in connections.values {
            connection.invalidation.yield(.identityLost)
            connection.invalidation.finish()
        }
    }

    /// The socket listener must verify the bundled launcher, using this peer's
    /// audit token. A same-user connection alone confers no registration right.
    func registerLauncher(on socket: Int32, context: GatewayLaunchContext,
                                 verifyLauncher: @Sendable (GatewaySocketPeer) throws -> Bool) throws -> GatewayLaunch {
        let peer = try inspector.socketPeer(socket)
        guard try verifyLauncher(peer) else { throw GatewayLaunchRegistryError.unauthorized }
        return try register(root: peer.identity, context: context)
    }

    public func registerLauncher(on socket: Int32, client: GatewayLaunchContext.Client,
                                 verifyLauncher: @Sendable (GatewaySocketPeer) throws -> Bool,
                                 resolveContext: @Sendable (GatewaySocketPeer, GatewayLaunchContext.Client) throws -> GatewayLaunchContext) throws -> GatewayLaunch {
        let peer = try inspector.socketPeer(socket)
        guard try verifyLauncher(peer) else { throw GatewayLaunchRegistryError.unauthorized }
        let context = try resolveContext(peer, client)
        guard context.client == client else { throw GatewayLaunchRegistryError.unauthorized }
        return try register(root: peer.identity, context: context)
    }

    /// Called by the app for a process it spawned. PID and context are supplied
    /// by the app's owner, never by an untrusted wire request.
    public func registerOwnedProcess(pid: pid_t, context: GatewayLaunchContext, chatID: UUID? = nil) throws -> GatewayLaunch {
        let process = try inspector.snapshot(pid)
        guard process.parentPID == getpid(), process.effectiveUID == geteuid() else {
            throw GatewayLaunchRegistryError.unauthorized
        }
        return try register(root: process.identity, context: context, chatID: chatID)
    }

    private func register(root: GatewayProcessIdentity, context: GatewayLaunchContext, chatID: UUID? = nil) throws -> GatewayLaunch {
        guard !closed else { throw GatewayLaunchRegistryError.closed }
        guard entries[root] == nil else { throw GatewayLaunchRegistryError.alreadyRegistered }
        // Descendants belong to their existing launch. Starting another
        // launcher cannot switch projects or undo a revocation.
        if !entries.isEmpty,
           try inspector.nearestAncestor(of: root, matching: { entries[$0] != nil }) != nil {
            throw GatewayLaunchRegistryError.unauthorized
        }
        guard try inspector.snapshot(root.pid).identity == root else {
            throw GatewayLaunchRegistryError.unauthorized
        }
        let launch = GatewayLaunch(id: UUID(), root: root, context: context, chatID: chatID)
        let stopWatching = watchExit(root.pid) { [weak self] in
            Task { await self?.finish(launch, reason: .launchExited) }
        }
        do {
            guard try inspector.snapshot(root.pid).identity == root else {
                throw GatewayLaunchRegistryError.unauthorized
            }
        } catch {
            stopWatching()
            throw error
        }
        entries[root] = .init(launch: launch, stopWatching: stopWatching)
        return launch
    }

    public func connect(on socket: Int32) throws -> Connection {
        guard !closed else { throw GatewayLaunchRegistryError.closed }
        let peer = try inspector.socketPeer(socket).identity
        guard entries[peer] == nil,
              let root = try inspector.nearestAncestor(of: peer, matching: { entries[$0] != nil }),
              let entry = entries[root], !entry.revoked else {
            throw GatewayLaunchRegistryError.unauthorized
        }
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Invalidation.self, bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.disconnect(id: id) }
        }
        connections[id] = .init(root: root, peer: peer, invalidation: continuation)
        entries[root]?.connections.insert(id)
        return .init(launch: entry.launch, invalidations: stream, id: id)
    }

    /// Check immediately before dispatch, including after an approval wait.
    /// Loss of the original peer or ancestry closes the borrowed capability.
    public func validate(_ connection: Connection) throws -> GatewayLaunchContext {
        guard let peer = connections[connection.id],
              let entry = entries[peer.root], !entry.revoked, entry.launch == connection.launch else {
            throw GatewayLaunchRegistryError.unauthorized
        }
        do {
            guard try inspector.nearestAncestor(of: peer.peer, matching: { $0 == peer.root }) == peer.root else {
                throw GatewayLaunchRegistryError.unauthorized
            }
        } catch {
            disconnect(id: connection.id, reason: .identityLost)
            throw error
        }
        return entry.launch.context
    }

    public func disconnect(_ connection: Connection) {
        disconnect(id: connection.id)
    }

    public func activeLaunches() -> [GatewayLaunch] {
        entries.values.filter { !$0.revoked }.map(\.launch)
    }

    @discardableResult
    public func revoke(id: UUID) -> Bool {
        guard let entry = entries.values.first(where: { $0.launch.id == id && !$0.revoked }) else { return false }
        // Keep a live revoked root until exit to prevent re-registration
        // of either this process or one of its descendants.
        entries[entry.launch.root]?.revoked = true
        for id in entry.connections { disconnect(id: id, reason: .revoked) }
        return true
    }

    public func shutdown() {
        closed = true
        for launch in entries.values.map(\.launch) { finish(launch, reason: .identityLost) }
    }

    private func finish(_ launch: GatewayLaunch, reason: Invalidation) {
        guard let entry = entries[launch.root], entry.launch.id == launch.id else { return }
        entries.removeValue(forKey: launch.root)
        entry.stopWatching()
        for id in entry.connections { disconnect(id: id, reason: reason) }
    }

    private func disconnect(id: UUID, reason: Invalidation? = nil) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        entries[connection.root]?.connections.remove(id)
        if let reason { connection.invalidation.yield(reason) }
        connection.invalidation.finish()
    }

    private static func watchProcess(_ pid: pid_t, onExit: @escaping @Sendable () -> Void) -> (@Sendable () -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler(handler: onExit)
        source.activate()
        return { source.cancel() }
    }
}
