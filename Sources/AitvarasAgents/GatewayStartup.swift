import Darwin
import Foundation
import AitvarasCore

public struct GatewayStartup: Sendable {
    public typealias Dial = @Sendable (GatewayEndpoint, ContinuousClock.Instant) async throws -> any GatewayFrameChannel
    public typealias OpenApp = @Sendable (URL, [String], Duration) async throws -> Void

    private let endpoint: GatewayEndpoint
    private let appBundle: URL
    private let environment: [String: String]
    private let dial: Dial
    private let openApp: OpenApp
    private let budget: Duration

    public init(endpoint: GatewayEndpoint, appBundle: URL,
                environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let binary = Bundle(url: appBundle)?.executableURL else { throw GatewayTransportError.missingBundle }
        let identity = try GatewayCodeIdentity(executable: binary, signingLocation: appBundle)
        self.init(endpoint: endpoint, appBundle: appBundle, environment: environment, budget: .seconds(10),
            dial: { endpoint, deadline in
                let channel = try GatewayUnixSocket.connect(endpoint, until: deadline)
                do {
                    guard try identity.matches(GatewayProcessInspector.live.socketPeer(channel.socketFD)) else {
                        throw GatewayTransportError.untrustedBinary
                    }
                    return channel
                } catch {
                    channel.stop()
                    throw error
                }
            }, openApp: Self.launch)
    }

    init(endpoint: GatewayEndpoint, appBundle: URL, environment: [String: String] = [:],
         budget: Duration, dial: @escaping Dial, openApp: @escaping OpenApp) {
        self.endpoint = endpoint
        self.appBundle = appBundle
        self.environment = environment
        self.budget = budget
        self.dial = dial
        self.openApp = openApp
    }

    public func connect(role: GatewayHandshakeRole) async throws -> any GatewayFrameChannel {
        let deadline = ContinuousClock.now.advanced(by: budget)
        var requested = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let channel: any GatewayFrameChannel
            do { channel = try await dial(endpoint, deadline) }
            catch GatewayTransportError.system(_, let code) where code == ENOENT || code == ECONNREFUSED {
                if !requested {
                    requested = true
                    try await openApp(appBundle, openArguments, ContinuousClock.now.duration(to: deadline))
                }
                try await ContinuousClock().sleep(until: min(deadline, .now.advanced(by: .milliseconds(60))))
                continue
            } catch GatewayTransportError.timeout {
                throw GatewayTransportError.appNotReady
            }
            do {
                let hello = try JSONEncoder().encode(GatewayHandshake(endpoint: endpoint, role: role))
                try await channel.writeFrame(hello, until: deadline)
                guard let frame = try await channel.readFrame(until: deadline), frame.count <= 1_024,
                      let reply = try? JSONDecoder().decode(GatewayHandshakeReply.self, from: frame) else {
                    throw GatewayTransportError.rejected
                }
                guard reply.profile == endpoint.profile, reply.status != .wrongProfile else {
                    throw GatewayTransportError.profileMismatch
                }
                guard reply.status == .ready else { throw GatewayTransportError.rejected }
                return channel
            } catch {
                channel.stop()
                if error as? GatewayTransportError == .timeout { throw GatewayTransportError.appNotReady }
                throw error
            }
        }
        throw GatewayTransportError.appNotReady
    }

    var openArguments: [String] {
        var arguments = ["-g"]
        if environment[AitvarasPaths.stateDirEnvVar]?.isEmpty == false {
            // LaunchServices may be running the default profile already.
            arguments += ["-n", "--env", "\(AitvarasPaths.stateDirEnvVar)=\(endpoint.stateDirectory.path)"]
        }
        for key in [AitvarasPaths.disableExternalIntegrationsEnvVar, AitvarasPaths.shareModelsEnvVar] where environment[key] == "1" {
            arguments += ["--env", "\(key)=1"]
        }
        return arguments + ["-a", appBundle.path]
    }

    private static func launch(_ bundle: URL, _ args: [String], _ remaining: Duration) async throws {
        guard remaining > .zero else { throw GatewayTransportError.appNotReady }
        let process = StreamingProcess(executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: args, currentDirectory: nil, environment: ProviderEnvironment.make())
        try process.start()
        process.closeInput()
        // The socket deadline does not wait for LaunchServices or child cleanup.
        Task.detached {
            let timeout = Task {
                do { try await Task.sleep(for: remaining) }
                catch { return }
                process.terminate()
            }
            defer { timeout.cancel() }
            _ = try? await process.waitForExit()
        }
    }
}

public enum GatewayStdioRelay {
    /// Both directions use the same bounded MCP framing. Closing either side
    /// stops the other and drops all in-flight requests on the app side.
    public static func run(stdio: any GatewayFrameChannel, socket: any GatewayFrameChannel) async throws {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await copy(from: stdio, to: socket) }
                group.addTask { try await copy(from: socket, to: stdio) }
                defer { socket.stop(); stdio.stop(); group.cancelAll() }
                _ = try await group.next()
            }
        } onCancel: {
            socket.stop()
            stdio.stop()
        }
    }

    private static func copy(from source: any GatewayFrameChannel, to target: any GatewayFrameChannel) async throws {
        while let frame = try await source.readFrame(until: nil) {
            try Task.checkCancellation()
            try await target.writeFrame(frame, until: .now.advanced(by: .seconds(5)))
        }
    }
}
