import Darwin
import Foundation
import AitvarasAgents

@main
struct AitvarasCommandMain {
    static func main() async {
        do {
            let bundle = try GatewayCodeIdentity.enclosingApp()
            let endpoint = GatewayEndpoint()
            let gateway = GatewayCLIConfiguration(executable: bundle.appendingPathComponent("Contents/MacOS/aitvaras-mcp"),
                stateDirectory: GatewayEndpoint.hasProfileOverride ? endpoint.stateDirectory : nil)
            let launcher = GatewayLauncher(gateway: gateway) { client in
                let startup = try GatewayStartup(endpoint: endpoint, appBundle: bundle)
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
