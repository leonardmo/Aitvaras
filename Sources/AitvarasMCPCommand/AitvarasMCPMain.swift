import Darwin
import Foundation
import AitvarasAgents

@main
struct AitvarasMCPMain {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if CommandLine.arguments.first.map({ ($0 as NSString).lastPathComponent }) == "zsh" {
                try await runProviderShell(arguments)
                return
            }
            if arguments.first == "--provider-hook" {
                guard arguments.count == 2 else { throw GatewayTransportError.invalidFrame }
                try await ProviderHookSocket.relay(socketPath: arguments[1])
                return
            }
            let startup = try GatewayStartup(endpoint: .init(), appBundle: GatewayCodeIdentity.enclosingApp())
            let socket = try await startup.connect(role: .relay)
            try await GatewayStdioRelay.run(stdio: GatewayFDChannel.standardIO(), socket: socket)
        } catch {
            FileHandle.standardError.write(Data("aitvaras-mcp: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func runProviderShell(_ arguments: [String]) async throws {
        let environment = ProcessInfo.processInfo.environment
        let shell = "/bin/zsh"
        guard arguments.count == 2, arguments[0] == "-c",
              let socket = environment["AITVARAS_SHELL_APPROVAL_SOCKET"]
        else { throw GatewayTransportError.invalidFrame }
        let command = arguments[1]
        // The same selected shell path is also used by non-tool OpenCode jobs.
        // Those jobs have no tool session and always remain in the parent sandbox.
        if let session = environment["OPENCODE_SESSION_ID"] {
            let response = try await ProviderHookSocket.exchange(socketPath: socket, request: .object([
                "session": .string(session), "command": .string(command),
                "directory": .string(FileManager.default.currentDirectoryPath)
            ]))
            if response["contained"]?.boolValue != true {
                guard let stdout = response["stdout"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
                      let stderr = response["stderr"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
                      let statusValue = response["exitCode"]?.doubleValue, let status = Int32(exactly: statusValue)
                else { throw GatewayTransportError.invalidFrame }
                try FileHandle.standardOutput.write(contentsOf: stdout)
                try FileHandle.standardError.write(contentsOf: stderr)
                exit(status)
            }
        }
        unsetenv("AITVARAS_SHELL_APPROVAL_SOCKET")
        setenv("SHELL", shell, 1)
        let argv = [strdup(shell), strdup("-c"), strdup(command), nil]
        defer { argv.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }) else { throw GatewayTransportError.invalidFrame }
        argv.withUnsafeBufferPointer { _ = execv(shell, $0.baseAddress!) }
        throw GatewayTransportError.system("start contained shell", errno)
    }
}
