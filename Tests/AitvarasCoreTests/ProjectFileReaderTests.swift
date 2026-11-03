import Foundation
import Testing
import Darwin
@testable import AitvarasConnectors

struct ProjectFileReaderTests {
    private struct Fixture {
        let directory: URL
        init() throws {
            let raw = FileManager.default.temporaryDirectory.appendingPathComponent("aitvaras-project-reader-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            let canonical = realpath(raw.path, nil)!
            directory = URL(fileURLWithPath: String(cString: canonical)); free(canonical)
        }
        func write(_ name: String, _ content: Data = Data("synthetic text".utf8)) throws {
            try content.write(to: directory.appendingPathComponent(name))
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
    @Test func readsTextAndListsOnlySafeEntries() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("note.md"); try f.write(".env"); try f.write("private.key")
        let reader = try ProjectFileReader(roots: [f.directory.path])
        let list = try reader.execute(tool: "aitvaras_project_list", root: 0, path: "")
        #expect(list.text == "note.md")
        let read = try reader.execute(tool: "aitvaras_project_read", root: 0, path: "note.md")
        #expect(read.text == "synthetic text" && read.bytes == 14)
        #expect(read.path == "project[0]/note.md")
    }
    @Test func refusesTraversalSecretsLinksAndNonregularFiles() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("note.md")
        try FileManager.default.createSymbolicLink(atPath: f.directory.appendingPathComponent("link").path, withDestinationPath: "note.md")
        try FileManager.default.linkItem(at: f.directory.appendingPathComponent("note.md"), to: f.directory.appendingPathComponent("hardlink"))
        let fifo = f.directory.appendingPathComponent("fifo").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let reader = try ProjectFileReader(roots: [f.directory.path])
        for path in ["../outside", "/etc/passwd", "a/../note.md", ".git/config", ".ssh/id_rsa", ".env", "keys/key", "Library/file", "note.md", "link", "hardlink", "fifo", "a//b", "a\\b"] {
            #expect(throws: (any Error).self) { try reader.execute(tool: "aitvaras_project_read", root: 0, path: path) }
        }
        #expect(throws: (any Error).self) { try reader.execute(tool: "shell", root: 0, path: "") }
        #expect(throws: (any Error).self) { try reader.execute(tool: "aitvaras_project_list", root: 1, path: "") }
    }
    @Test func rejectsBroadRootsAndRootSymlinks() throws {
        let f = try Fixture(); defer { f.remove() }
        let alias = f.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.directory)
        for root in ["/", "/Users", FileManager.default.homeDirectoryForCurrentUser.path, alias.path] {
            #expect(throws: (any Error).self) { try ProjectFileReader(roots: [root]) }
        }
    }
    @Test func boundsBinaryFileSizeCallsAndTotalBytes() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("binary", Data([0, 1, 2])); try f.write("huge", Data(repeating: 65, count: 65_537))
        try f.write("text", Data(repeating: 65, count: 65_536))
        let reader = try ProjectFileReader(roots: [f.directory.path])
        for path in ["binary", "huge"] {
            #expect(throws: (any Error).self) { try reader.execute(tool: "aitvaras_project_read", root: 0, path: path) }
        }
        for _ in 0..<8 { _ = try reader.execute(tool: "aitvaras_project_read", root: 0, path: "text") }
        #expect(throws: (any Error).self) { try reader.execute(tool: "aitvaras_project_read", root: 0, path: "text") }
        let calls = try ProjectFileReader(roots: [f.directory.path])
        for _ in 0..<32 { _ = try calls.execute(tool: "aitvaras_project_list", root: 0, path: "") }
        #expect(throws: (any Error).self) { try calls.execute(tool: "aitvaras_project_list", root: 0, path: "") }
    }
    @Test func rootHandleIsPinnedAndCancellationRevokesSnapshot() throws {
        let f = try Fixture(); defer { f.remove() }
        let project = f.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: project.appendingPathComponent("note"))
        let reader = try ProjectFileReader(roots: [project.path])
        try FileManager.default.moveItem(at: project, to: f.directory.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: project.appendingPathComponent("note"))
        #expect(try reader.execute(tool: "aitvaras_project_read", root: 0, path: "note").text == "original")
        reader.cancel()
        #expect(throws: (any Error).self) { try reader.execute(tool: "aitvaras_project_read", root: 0, path: "note") }
        let revoked = try ProjectFileReader(roots: [])
        #expect(throws: (any Error).self) { try revoked.execute(tool: "aitvaras_project_read", root: 0, path: "note") }
    }
    @Test func oversizedDirectoryFailsClosed() throws {
        let f = try Fixture(); defer { f.remove() }
        for i in 0..<201 { try f.write("entry-\(i)") }
        let reader = try ProjectFileReader(roots: [f.directory.path])
        #expect(throws: (any Error).self) { try reader.execute(tool: "aitvaras_project_list", root: 0, path: "") }
    }
    @Test func asynchronousReadHonorsCancellation() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("note")
        let reader = try ProjectFileReader(roots: [f.directory.path])
        #expect(try await reader.executeAsync(tool: "aitvaras_project_read", root: 0, path: "note").text == "synthetic text")
        reader.cancel()
        do {
            _ = try await reader.executeAsync(tool: "aitvaras_project_read", root: 0, path: "note")
            Issue.record("Cancelled snapshot still readable")
        } catch { #expect(error is ProjectFileReader.Denied) }
    }
    @Test func rootPreparationCancellationBeforeAndAfterDeliveryRevokesLaunch() async throws {
        let pending = ProjectFileReader.Preparation(roots: [])
        pending.cancel()
        do {
            _ = try await pending.prepare()
            Issue.record("Cancelled preparation returned a reader")
        } catch { #expect(error is ProjectFileReader.Denied) }
        let delivered = ProjectFileReader.Preparation(roots: [])
        _ = try await delivered.prepare()
        delivered.cancel()
        #expect(throws: (any Error).self) { try delivered.ensureActive() }
    }
}
