import Darwin
import Foundation
import Synchronization
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(1))) struct GatewayLaunchRegistryTests {
    @Test func registrationAndAdmissionRequireVerifiedLiveAncestry() async throws {
        let fixture = GatewayRegistryFixture()
        let context = GatewayLaunchContext(client: .claude, projectID: UUID())
        await #expect(throws: GatewayLaunchRegistryError.unauthorized) {
            try await fixture.registry.registerLauncher(on: 10, context: context) { _ in false }
        }
        await #expect(throws: GatewayLaunchRegistryError.unauthorized) {
            try await fixture.registry.registerOwnedProcess(pid: 10, context: context)
        }
        let launch = try await fixture.register(10, context: context)
        await #expect(throws: GatewayLaunchRegistryError.alreadyRegistered) {
            try await fixture.register(10, context: .init(client: .codex, projectID: nil))
        }
        for socket: Int32 in [10, 13] {
            await #expect(throws: GatewayLaunchRegistryError.unauthorized) {
                try await fixture.registry.connect(on: socket)
            }
        }
        let connection = try await fixture.registry.connect(on: 12)
        #expect(connection.launch == launch)
        #expect(try await fixture.registry.validate(connection) == context)
        #expect(await fixture.registry.activeLaunches() == [launch])

        fixture.setParent(of: 11, to: 1)
        await #expect(throws: GatewayLaunchRegistryError.unauthorized) {
            try await fixture.registry.validate(connection)
        }
        var invalidations = connection.invalidations.makeAsyncIterator()
        #expect(await invalidations.next() == .identityLost)
        #expect(await invalidations.next() == nil)
    }

    @Test func appOwnedLaunchUsesTheSpawnedChildIdentity() async throws {
        let fixture = GatewayRegistryFixture()
        fixture.setParent(of: 10, to: getpid())
        let projectID = UUID(), chatID = UUID()
        let gateway = GatewayChatLaunch(configuration: .init(executable: URL(fileURLWithPath: "/fixture/relay"),
            stateDirectory: nil), registry: fixture.registry)
        let register = gateway.register(client: .codex, chatID: chatID, projectID: projectID, permissions: .fullAccess)
        _ = try await register(10)

        let connection = try await fixture.registry.connect(on: 12)
        #expect(connection.launch.root.pid == 10)
        #expect(connection.launch.chatID == chatID)
        #expect(try await fixture.registry.validate(connection) == .init(client: .codex, projectID: projectID, permissions: .fullAccess))
    }

    @Test func revokeInvalidatesConnectionsWithoutAffectingAnotherLaunch() async throws {
        let fixture = GatewayRegistryFixture()
        let firstContext = GatewayLaunchContext(client: .claude, projectID: UUID())
        let secondContext = GatewayLaunchContext(client: .codex, projectID: UUID())
        let firstLaunch = try await fixture.register(10, context: firstContext)
        let first = try await fixture.registry.connect(on: 12)
        let secondLaunch = try await fixture.register(13, context: secondContext)
        let second = try await fixture.registry.connect(on: 15)

        #expect(first.launch == firstLaunch)
        #expect(second.launch == secondLaunch)
        await #expect(throws: GatewayLaunchRegistryError.unauthorized) {
            try await fixture.register(11, context: secondContext)
        }
        #expect(await fixture.registry.revoke(id: firstLaunch.id))
        #expect(!(await fixture.registry.revoke(id: firstLaunch.id)))

        var invalidations = first.invalidations.makeAsyncIterator()
        #expect(await invalidations.next() == .revoked)
        #expect(await invalidations.next() == nil)
        await #expect(throws: GatewayLaunchRegistryError.unauthorized) {
            try await fixture.registry.validate(first)
        }
        await #expect(throws: GatewayLaunchRegistryError.unauthorized) {
            try await fixture.registry.connect(on: 12)
        }
        await #expect(throws: GatewayLaunchRegistryError.alreadyRegistered) {
            try await fixture.register(10, context: firstContext)
        }
        await #expect(throws: GatewayLaunchRegistryError.unauthorized) {
            try await fixture.register(11, context: secondContext)
        }
        #expect(await fixture.registry.activeLaunches() == [secondLaunch])
        #expect(try await fixture.registry.validate(second) == secondContext)
    }

    @Test func launchExitNotifiesAnAlreadyConnectedPeer() async throws {
        let fixture = GatewayRegistryFixture()
        let launch = try await fixture.register(10, context: .init(client: .claude, projectID: nil))
        let connection = try await fixture.registry.connect(on: 12)
        let onExit = try #require(fixture.exitHandler(pid: 10))
        onExit()

        var invalidations = connection.invalidations.makeAsyncIterator()
        #expect(await invalidations.next() == .launchExited)
        #expect(await invalidations.next() == nil)
        #expect(await fixture.registry.activeLaunches().isEmpty)
        #expect(!(await fixture.registry.revoke(id: launch.id)))
        await #expect(throws: GatewayLaunchRegistryError.unauthorized) {
            try await fixture.registry.validate(connection)
        }
    }

    @Test func inspectionDenialAndPIDReuseCannotKeepAnOldConnection() async throws {
        let fixture = GatewayRegistryFixture()
        let context = GatewayLaunchContext(client: .codex, projectID: nil)
        _ = try await fixture.register(10, context: context)
        let connection = try await fixture.registry.connect(on: 12)
        fixture.denyInspection(pid: 11)
        let denied = GatewayProcessInspectionError.system(operation: "fixture inspection", code: EPERM)
        await #expect(throws: denied) { try await fixture.registry.validate(connection) }
        await #expect(throws: denied) { try await fixture.registry.connect(on: 12) }
        var invalidations = connection.invalidations.makeAsyncIterator()
        #expect(await invalidations.next() == .identityLost)

        fixture.denyInspection(pid: nil)
        fixture.reuseRootPID()
        await #expect(throws: GatewayProcessInspectionError.invalidAncestry) {
            try await fixture.registry.connect(on: 12)
        }
        let newLaunch = try await fixture.register(10, context: context)
        #expect(newLaunch.root.startSeconds == 99)
        let newConnection = try await fixture.registry.connect(on: 14)
        #expect(newConnection.launch == newLaunch)
        await fixture.registry.shutdown()
        var shutdown = newConnection.invalidations.makeAsyncIterator()
        #expect(await shutdown.next() == .identityLost)
        #expect(await fixture.registry.activeLaunches().isEmpty)
        await #expect(throws: GatewayLaunchRegistryError.closed) {
            try await fixture.registry.connect(on: 14)
        }
    }
}

private struct GatewayRegistryFixture: Sendable {
    private struct Processes: Sendable {
        var snapshots = [
            10: GatewayRegistryFixture.snapshot(pid: 10, parent: 1),
            11: GatewayRegistryFixture.snapshot(pid: 11, parent: 10),
            12: GatewayRegistryFixture.snapshot(pid: 12, parent: 11),
            13: GatewayRegistryFixture.snapshot(pid: 13, parent: 1),
            15: GatewayRegistryFixture.snapshot(pid: 15, parent: 13)
        ] as [pid_t: GatewayProcessSnapshot]
        var deniedPID: pid_t?
        var exitHandlers: [pid_t: @Sendable () -> Void] = [:]
    }

    private final class ProcessState: Sendable {
        let mutex = Mutex(Processes())
    }

    let registry: GatewayLaunchRegistry
    private let processes: ProcessState

    init() {
        let processes = ProcessState()
        self.processes = processes
        let lookup: @Sendable (pid_t) throws -> GatewayProcessSnapshot = { pid in
            try processes.mutex.withLock { state in
                guard state.deniedPID != pid else {
                    throw GatewayProcessInspectionError.system(operation: "fixture inspection", code: EPERM)
                }
                guard let process = state.snapshots[pid] else {
                    throw GatewayProcessInspectionError.system(operation: "fixture inspection", code: ESRCH)
                }
                return process
            }
        }
        registry = GatewayLaunchRegistry(inspector: .init(snapshot: lookup, socketPeer: {
            try .init(identity: lookup($0).identity, auditToken: Data())
        }), watchExit: { pid, handler in
            processes.mutex.withLock { $0.exitHandlers[pid] = handler }
            return {}
        })
    }

    func exitHandler(pid: pid_t) -> (@Sendable () -> Void)? {
        processes.mutex.withLock { $0.exitHandlers[pid] }
    }

    func register(_ pid: pid_t, context: GatewayLaunchContext) async throws -> GatewayLaunch {
        try await registry.registerLauncher(on: pid, context: context) { $0.identity.pid == pid }
    }

    func setParent(of pid: pid_t, to parent: pid_t) {
        processes.mutex.withLock { $0.snapshots[pid] = Self.snapshot(pid: pid, parent: parent) }
    }

    func denyInspection(pid: pid_t?) {
        processes.mutex.withLock { $0.deniedPID = pid }
    }

    func reuseRootPID() {
        processes.mutex.withLock {
            $0.snapshots[10] = Self.snapshot(pid: 10, parent: 1, start: 99)
            $0.snapshots[14] = Self.snapshot(pid: 14, parent: 10, start: 100)
        }
    }

    private static func snapshot(pid: pid_t, parent: pid_t, start: UInt64? = nil) -> GatewayProcessSnapshot {
        .init(identity: .init(pid: pid, startSeconds: start ?? UInt64(pid), startMicroseconds: 1),
              parentPID: parent, effectiveUID: geteuid())
    }
}
