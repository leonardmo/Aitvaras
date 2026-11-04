// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AvatarPolicyChecks", platforms: [.macOS("26.0")], targets: [
    .target(name: "AitvarasCore", path: "Core"),
    .testTarget(name: "AvatarPolicyTests", dependencies: ["AitvarasCore"], path: "Tests")
])
