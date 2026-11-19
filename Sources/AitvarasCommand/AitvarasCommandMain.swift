import Darwin
import Foundation
import AitvarasAgents

@main
struct AitvarasCommandMain {
    static func main() async {
        do {
            let launcher = GatewayLauncher { client in
                let startup = try GatewayStartup(endpoint: .init(), appBundle: GatewayCodeIdentity.enclosingApp())
                let channel = try await startup.connect(role: .register(client))
                channel.stop()
            }
            exit(try await launcher.run(arguments: Array(CommandLine.arguments.dropFirst()),
                                        environment: ProcessInfo.processInfo.environment))
        } catch {
            FileHandle.standardError.write(Data("aitvaras: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
