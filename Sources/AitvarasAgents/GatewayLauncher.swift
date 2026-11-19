import Darwin
import Foundation
import CGatewayPTY

public enum GatewayLauncherError: Error, Equatable, LocalizedError, Sendable {
    case usage, credentialOverride, unsupportedConfiguration, missingCLI, invalidProcess

    public var errorDescription: String? {
        switch self {
        case .usage: "Usage: aitvaras claude|codex [arguments]"
        case .credentialOverride: "Remove API credentials and provider endpoint overrides before launching."
        case .unsupportedConfiguration: "This configuration override cannot be used with the Aitvaras launcher."
        case .missingCLI: "The selected CLI is not installed or not executable."
        case .invalidProcess: "The CLI could not be started."
        }
    }
}

public struct GatewayLauncher: Sendable {
    public typealias Register = @Sendable (GatewayLaunchContext.Client) async throws -> Void
    public typealias Locate = @Sendable (GatewayLaunchContext.Client, [String: String]) -> URL?
    public typealias Supervise = @Sendable (URL, [String], [String: String]) throws -> Int32

    private let register: Register
    private let locate: Locate
    private let supervise: Supervise

    public init(register: @escaping Register) {
        self.init(register: register, locate: { client, env in
            ProviderLocator.executable(for: client == .claude ? .claude : .codex, environment: env)
        }, supervise: { try GatewayPTY.run(executable: $0, arguments: $1, environment: $2) })
    }

    init(register: @escaping Register, locate: @escaping Locate, supervise: @escaping Supervise) {
        self.register = register
        self.locate = locate
        self.supervise = supervise
    }

    public func run(arguments: [String], environment: [String: String]) async throws -> Int32 {
        guard let command = arguments.first, let client = GatewayLaunchContext.Client(rawValue: command) else {
            throw GatewayLauncherError.usage
        }
        let arguments = Array(arguments.dropFirst())
        let overrides = environment.filter { ["CLAUDE_CONFIG_DIR", "CODEX_HOME"].contains($0.key) }
        let filtered = ProviderEnvironment.make(inherited: environment, overrides: overrides)
        guard environment.keys.allSatisfy({ filtered[$0] != nil }) else { throw GatewayLauncherError.credentialOverride }
        try Self.checkArguments(arguments, client: client)
        guard let cli = locate(client, environment) else { throw GatewayLauncherError.missingCLI }
        try Task.checkCancellation()
        try await register(client)
        try Task.checkCancellation()
        return try supervise(cli, arguments, environment)
    }

    private static func checkArguments(_ args: [String], client: GatewayLaunchContext.Client) throws {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" { return }
            let flag = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            if ["--api-key", "--base-url", "--api-base", "--provider", "--model-provider"].contains(flag) {
                throw GatewayLauncherError.credentialOverride
            }
            if client == .claude && flag == "--settings" { throw GatewayLauncherError.unsupportedConfiguration }
            if client == .codex && (flag == "--config" || arg.hasPrefix("-c")) {
                let assignment: String
                if flag == "--config", arg != flag { assignment = String(arg.dropFirst(flag.count + 1)) }
                else if arg == "-c" || arg == "--config" {
                    index += 1
                    guard index < args.count else { throw GatewayLauncherError.unsupportedConfiguration }
                    assignment = args[index]
                } else { assignment = String(arg.dropFirst(2)) }
                let key = assignment.prefix { $0 != "=" }.trimmingCharacters(in: .whitespaces)
                guard assignment.contains("="), ["model", "model_reasoning_effort", "approval_policy", "sandbox_mode"].contains(key)
                else { throw GatewayLauncherError.unsupportedConfiguration }
            }
            index += 1
        }
    }
}

enum GatewayPTY {
    static func run(executable: URL, arguments: [String], environment: [String: String],
                    interactive: Bool = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 && isatty(STDERR_FILENO) == 1,
                    input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, testTimeoutMS: Int32 = 0)
        throws -> Int32 {
        let path = executable.path
        let env = environment.keys.sorted().map { key in "\(key)=\(environment[key, default: ""])" }
        guard executable.isFileURL, path.hasPrefix("/"),
              environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }),
              !([path] + arguments + env).contains(where: { $0.contains("\0") }) else { throw GatewayLauncherError.invalidProcess }
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup($0) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw GatewayLauncherError.invalidProcess
        }
        let status = path.withCString { binary in
            argv.withUnsafeBufferPointer { args in
                envp.withUnsafeBufferPointer { values in
                    aitvaras_supervise(binary, args.baseAddress!, values.baseAddress!, interactive ? 1 : 0, input, output, testTimeoutMS)
                }
            }
        }
        guard status >= 0 else { throw GatewayTransportError.system("supervise CLI", errno) }
        return status
    }
}
