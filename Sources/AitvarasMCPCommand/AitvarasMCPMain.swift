import Darwin
import Foundation
import AitvarasAgents

@main
struct AitvarasMCPMain {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        do {
            let startup = try GatewayStartup(endpoint: .init(), appBundle: GatewayCodeIdentity.enclosingApp())
            let socket = try await startup.connect(role: .relay)
            try await GatewayStdioRelay.run(stdio: GatewayFDChannel.standardIO(), socket: socket)
        } catch {
            FileHandle.standardError.write(Data("aitvaras-mcp: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
