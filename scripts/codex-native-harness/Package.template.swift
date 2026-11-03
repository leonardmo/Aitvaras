// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CodexNativeChecks", platforms: [.macOS("26.0")], targets: [
    .target(name: "AitvarasCore", path: "Core"),
    .target(name: "AitvarasConnectors", dependencies: ["AitvarasCore"], path: "Connectors",
            resources: [.process("Resources")]),
    .testTarget(name: "CodexNativeTests", dependencies: ["AitvarasCore", "AitvarasConnectors"], path: "Tests")
])
