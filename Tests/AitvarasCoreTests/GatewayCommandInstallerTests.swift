import Foundation
import Testing
import AitvarasAgents

@Suite(.timeLimit(.minutes(1))) struct GatewayCommandInstallerTests {
    @Test func installIsIdempotentAndUninstallLeavesOtherPathsAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("bundled")
        try Data().write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let installer = GatewayCommandInstaller(home: root, launcher: launcher)
        #expect(try installer.status() == .absent)
        try installer.uninstall()
        try installer.install()
        try installer.install()
        #expect(try installer.status() == .installed)
        #expect(installer.onPath("/usr/bin:\(installer.bin.path)"))
        #expect(!installer.onPath("/usr/bin:.local/bin:\(installer.bin.path)-other"))
        try installer.uninstall()
        #expect(try installer.status() == .absent)

        try Data("keep".utf8).write(to: installer.command)
        #expect(throws: GatewayCommandInstaller.Failure.occupied) { try installer.install() }
        #expect(throws: GatewayCommandInstaller.Failure.occupied) { try installer.uninstall() }
        #expect(try String(contentsOf: installer.command, encoding: .utf8) == "keep")
        try FileManager.default.removeItem(at: installer.command)
        try FileManager.default.createSymbolicLink(atPath: installer.command.path, withDestinationPath: "/example/dangling")
        #expect(throws: GatewayCommandInstaller.Failure.occupied) { try installer.install() }
        #expect(throws: GatewayCommandInstaller.Failure.occupied) { try installer.uninstall() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installer.command.path) == "/example/dangling")
    }

    @Test func refuseSymlinkedBinParents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".local"), withDestinationURL: root)
        let launcher = root.appendingPathComponent("bundled")
        try Data().write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let installer = GatewayCommandInstaller(home: root, launcher: launcher)
        #expect(throws: GatewayCommandInstaller.Failure.unsafeDirectory) { try installer.install() }
        #expect(throws: GatewayCommandInstaller.Failure.unsafeDirectory) { try installer.uninstall() }
    }
}
