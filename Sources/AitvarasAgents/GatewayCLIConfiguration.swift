import Darwin
import Foundation
import AitvarasCore

/// The same reserved stdio entry is used by terminal and Chat launches.
public struct GatewayCLIConfiguration: Sendable {
    public static let serverName = "aitvaras"
    private let executable: URL
    private let stateDirectory: URL?

    public init(executable: URL, stateDirectory: URL?) {
        self.executable = executable
        self.stateDirectory = stateDirectory
    }

    var server: AgentMCPServer {
        .init(command: executable.path, env: stateDirectory.map {
            [AitvarasPaths.stateDirEnvVar: .literal($0.path)]
        } ?? [:])
    }

    var codexArguments: [String] {
        let command = Self.tomlString(executable.path)
        let profile = stateDirectory.map {
            ", env = { \(AitvarasPaths.stateDirEnvVar) = \(Self.tomlString($0.path)) }"
        } ?? ""
        return ["-c", "mcp_servers.\(Self.serverName)={ command = \(command), args = [], enabled = true\(profile) }"]
    }

    // JSONValue leaves slashes alone. TOML additionally requires DEL to be escaped.
    private static func tomlString(_ value: String) -> String {
        JSONValue.string(value).jsonString.replacingOccurrences(of: "\u{7f}", with: "\\u007f")
    }

    func withLaunchArguments(_ arguments: [String], client: GatewayLaunchContext.Client,
                             run: ([String]) throws -> Int32) throws -> Int32 {
        if client == .codex { return try run(codexArguments + arguments) }
        var template = FileManager.default.temporaryDirectory.appendingPathComponent("aitvaras-mcp.XXXXXX").path.utf8CString
        guard let directory = template.withUnsafeMutableBufferPointer({ pointer in
            mkdtemp(pointer.baseAddress!).map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) }
        }) else { throw GatewayTransportError.system("create launcher MCP directory", errno) }
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mcp.json")
        var entry: [String: JSONValue] = ["type": .string("stdio"), "command": .string(executable.path), "args": .array([])]
        if let stateDirectory { entry["env"] = .object([AitvarasPaths.stateDirEnvVar: .string(stateDirectory.path)]) }
        let config = JSONValue.object(["mcpServers": .object([Self.serverName: .object(entry)])])
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GatewayTransportError.system("create launcher MCP file", errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            guard fchmod(fd, 0o600) == 0 else { throw GatewayTransportError.system("protect launcher MCP file", errno) }
            try handle.write(contentsOf: Data(config.jsonString.utf8))
            try handle.close()
        } catch { try? handle.close(); throw error }
        // Claude's variadic flag must not consume a user's positional prompt.
        let end = arguments.firstIndex(of: "--") ?? arguments.endIndex
        return try run(Array(arguments[..<end]) + ["--mcp-config", file.path] + Array(arguments[end...]))
    }
}

/// Chat can register only app-owned children, through its in-process registry.
public struct GatewayChatLaunch: Sendable {
    let configuration: GatewayCLIConfiguration
    let registry: GatewayLaunchRegistry
    private let cancelApprovals: @Sendable (UUID) async -> Void

    public init(configuration: GatewayCLIConfiguration, registry: GatewayLaunchRegistry,
                cancelApprovals: @escaping @Sendable (UUID) async -> Void = { _ in }) {
        self.configuration = configuration
        self.registry = registry
        self.cancelApprovals = cancelApprovals
    }

    func register(client: GatewayLaunchContext.Client, chatID: UUID, projectID: UUID?) -> AgentWire.RegisterProcess {
        { pid in
            let launch = try await registry.registerOwnedProcess(pid: pid, context: .init(client: client, projectID: projectID),
                                                                 chatID: chatID)
            return { await cancelApprovals(launch.id) }
        }
    }
}
