// Harness-only discovery stubs. The actual native client, process wrapper,
// protocol DTOs and read-only endpoint validator are compiled unchanged.
import Foundation
enum DelegateConnector {
    enum Kind { case codex }
    struct Agent { var path: String }
    static func findAgent(kind: Kind) -> Agent? { nil }
}
struct CodexSessionReader {
    static func findNode() -> String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}\\z", options: .regularExpression) != nil
    }
    static func environment(node: String) -> [String: String] { [:] }
    static func canonicalProfileHome(explicit: URL?, inherited: [String: String]) -> URL {
        (explicit ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")).standardizedFileURL.resolvingSymlinksInPath()
    }
}
