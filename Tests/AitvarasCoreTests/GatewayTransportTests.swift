import Darwin
import Foundation
import Synchronization
import Testing
import AitvarasCore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(1))) struct GatewayTransportTests {
    @Test func incrementalFramingRejectsOversizedAndTruncatedMessages() throws {
        var decoder = GatewayFrameDecoder()
        #expect(try decoder.append(Data("{\"a\"".utf8)).isEmpty)
        let frames = try decoder.append(Data(":1}\r\n{}\n".utf8))
        #expect(frames.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{}"])
        #expect(try decoder.append(Data(repeating: 65, count: GatewayFrameDecoder.maximumBytes)).isEmpty)
        #expect(throws: GatewayTransportError.frameTooLarge) { try decoder.append(Data([65])) }
        #expect(throws: GatewayTransportError.invalidFrame) { try decoder.finish() }
        let root = URL(fileURLWithPath: "/example/" + String(repeating: "a", count: 128))
        #expect(throws: GatewayTransportError.pathTooLong) {
            try GatewayUnixSocket.address(GatewayEndpoint(stateDirectory: root).socketURL.path)
        }
    }

    @Test func startupOpensOnceForTheRequestedProfileAndChecksReply() async throws {
        let endpoint = GatewayEndpoint(stateDirectory: URL(fileURLWithPath: "/example/profile"))
        let reply = try JSONEncoder().encode(GatewayHandshakeReply(profile: endpoint.profile, status: .ready))
        let peer = GatewayMemoryChannel()
        peer.offer(reply)
        let state = Mutex((attempts: 0, opens: [[String]]()))
        let bundle = URL(fileURLWithPath: "/example/Aitvaras.app")
        let startup = GatewayStartup(endpoint: endpoint, appBundle: bundle,
            environment: [AitvarasPaths.stateDirEnvVar: endpoint.stateDirectory.path,
                          AitvarasPaths.disableExternalIntegrationsEnvVar: "1"], budget: .seconds(1),
            dial: { route, _ in
                #expect(route == endpoint)
                let attempt = state.withLock { $0.attempts += 1; return $0.attempts }
                if attempt == 1 { throw GatewayTransportError.system("connect", ENOENT) }
                return peer
            }, openApp: { app, arguments, remaining in
                #expect(app == bundle)
                #expect(remaining <= .seconds(1))
                state.withLock { $0.opens.append(arguments) }
            })
        _ = try await startup.connect(role: .register(.codex))
        let expectedState = AitvarasPaths.stateDirEnvVar + "=" + endpoint.stateDirectory.path
        #expect(state.withLock { $0.opens } == [["-g", "-n", "--env", expectedState,
            "--env", AitvarasPaths.disableExternalIntegrationsEnvVar + "=1", "-a", bundle.path]])
        let written = try #require(peer.written.first)
        let hello = try JSONDecoder().decode(GatewayHandshake.self, from: written)
        #expect(hello.request == .register(.codex))
        #expect(hello.profile == endpoint.profile)
    }

    @Test func wrongProfileClosesConnectionAndMissingAppTimesOut() async throws {
        let endpoint = GatewayEndpoint(stateDirectory: URL(fileURLWithPath: "/example/profile"))
        let bundle = URL(fileURLWithPath: "/example/Aitvaras.app")
        let peer = GatewayMemoryChannel()
        peer.offer(try JSONEncoder().encode(GatewayHandshakeReply(profile: "other", status: .ready)))
        let mismatch = GatewayStartup(endpoint: endpoint, appBundle: bundle, budget: .seconds(1),
            dial: { _, _ in peer }, openApp: { _, _, _ in Issue.record("Connected socket must not open another app") })
        await #expect(throws: GatewayTransportError.profileMismatch) { try await mismatch.connect(role: .relay) }
        #expect(peer.stopped)

        let starts = Mutex(0)
        let absent = GatewayStartup(endpoint: endpoint, appBundle: bundle, budget: .milliseconds(100),
            dial: { _, _ in throw GatewayTransportError.system("connect", ENOENT) },
            openApp: { _, _, _ in starts.withLock { $0 += 1 } })
        await #expect(throws: GatewayTransportError.appNotReady) { try await absent.connect(role: .relay) }
        #expect(starts.withLock { $0 } == 1)
    }

    @Test func stdioRelaysBothDirectionsAndStopsBothEndsOnEOF() async throws {
        let stdio = GatewayMemoryChannel(), wire = GatewayMemoryChannel()
        let start = Task { try await GatewayStdioRelay.run(stdio: stdio, socket: wire) }
        defer { stdio.stop(); wire.stop(); start.cancel() }
        stdio.offer(Data("fixture request".utf8))
        wire.offer(Data("fixture response".utf8))
        for _ in 0..<100 {
            if !stdio.written.isEmpty, !wire.written.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(stdio.written == [Data("fixture response".utf8)])
        #expect(wire.written == [Data("fixture request".utf8)])
        stdio.stop()
        try await start.value
        #expect(wire.stopped)
    }

    @Test func launcherPreservesArgumentsProfileAndRegisterBeforeSpawn() async throws {
        let process = Mutex([String]())
        let env = ["CLAUDE_CONFIG_DIR": "/example/claude", "CODEX_HOME": "/example/codex",
                   "AITVARAS_STATE_DIR": "/example/state", "TERM": "xterm"]
        let executable = URL(fileURLWithPath: "/example/claude")
        let launcher = GatewayLauncher(register: { client in
            #expect(client == .claude)
            process.withLock { $0.append("register") }
        }, locate: { _, received in
            #expect(received == env)
            return executable
        }, supervise: { binary, arguments, received in
            #expect(binary == executable)
            #expect(arguments == ["--model", "haiku", "--", "literal input"])
            #expect(received == env)
            process.withLock { $0.append("spawn") }
            return 42
        })
        #expect(try await launcher.run(arguments: ["claude", "--model", "haiku", "--", "literal input"], environment: env) == 42)
        #expect(process.withLock { $0 } == ["register", "spawn"])
    }

    @Test func launcherRejectsOverridesAndDoesNotSpawnWithoutRegistration() async throws {
        let launcher = GatewayLauncher(register: { _ in throw GatewayTransportError.rejected },
            locate: { _, _ in URL(fileURLWithPath: "/example/codex") },
            supervise: { _, _, _ in Issue.record("Spawn requires registration"); return 0 })
        await #expect(throws: GatewayLauncherError.credentialOverride) {
            try await launcher.run(arguments: ["codex"], environment: ["OPENAI_BASE_URL": "https://example.invalid"])
        }
        await #expect(throws: GatewayLauncherError.unsupportedConfiguration) {
            try await launcher.run(arguments: ["codex", "-c", "model_provider='example'"], environment: [:])
        }
        await #expect(throws: GatewayTransportError.rejected) { try await launcher.run(arguments: ["codex"], environment: [:]) }
    }

    @Test func pipeSupervisorReapsFiniteChildAndReturnsExitStatus() throws {
        let status = try GatewayPTY.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "test \"$CLAUDE_CONFIG_DIR\" = /example/claude && exit 37"],
            environment: ["CLAUDE_CONFIG_DIR": "/example/claude"], interactive: false, testTimeoutMS: 3_000)
        #expect(status == 37)
    }
}

private final class GatewayMemoryChannel: GatewayFrameChannel, @unchecked Sendable {
    private let stream = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(4))
    private let state = Mutex((stopped: false, written: [Data]()))
    var stopped: Bool { state.withLock { $0.stopped } }
    var written: [Data] { state.withLock { $0.written } }
    // The fixture has one read per handshake or one relay reader.
    func readFrame(until deadline: ContinuousClock.Instant?) async throws -> Data? {
        var iterator = stream.stream.makeAsyncIterator()
        return await iterator.next()
    }
    func writeFrame(_ frame: Data, until deadline: ContinuousClock.Instant?) async throws {
        state.withLock { $0.written.append(frame) }
    }
    func offer(_ frame: Data) { stream.continuation.yield(frame) }
    func stop() {
        state.withLock { $0.stopped = true }
        stream.continuation.finish()
    }
}
