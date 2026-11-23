import Foundation

/// Codex applies session-flag hooks only when the exact declaration has been
/// approved. Both the declaration and its approval live in this app-server.
struct CodexCommandHook: Sendable {
    private static let matcher = "^Bash$|^mcp__"
    private static let timeout = 1_810
    static let approvalTimeout: Duration = .seconds(timeout - 10)
    private static let key = "/<session-flags>/config.toml:pre_tool_use:0:0"
    static let rejected: JSONValue = .object(["hookSpecificOutput": .object([
        "hookEventName": .string("PreToolUse"), "permissionDecision": .string("deny"),
        "permissionDecisionReason": .string("Aitvaras did not authorize this tool call.")
    ])])
    static let allowed: JSONValue = .object([:])

    let socket: ProviderHookSocket
    let identity: GatewayCodeIdentity
    private let command: String

    init(helper: URL) throws {
        identity = try GatewayCodeIdentity(executable: helper)
        socket = try ProviderHookSocket()
        // A relay error becomes a normal Codex denial. The app cancels its
        // approval deadline before Codex's own subprocess timeout.
        command = "\(Self.shellQuote(helper.path)) --provider-hook \(Self.shellQuote(socket.url.path))"
            + " || /usr/bin/printf '%s\\n' \(Self.shellQuote(Self.rejected.jsonString))"
    }

    var arguments: [String] {
        let toml = JSONValue.string(command).jsonString.replacingOccurrences(of: "\u{7f}", with: "\\u007f")
        return ["-c", "hooks.PreToolUse=[{matcher=\"\(Self.matcher)\",hooks=[{type=\"command\",command=\(toml),timeout=\(Self.timeout)}]}]"]
    }

    func trustedConfiguration(_ report: JSONValue) throws -> JSONValue {
        guard let reported = entry(in: report), let hash = reported["currentHash"]?.stringValue,
              hash.hasPrefix("sha256:"), hash.count == 71 else { throw AgentFailure.unsupported }
        return .object([
            "PreToolUse": .array([.object(["matcher": .string(Self.matcher), "hooks": .array([.object([
                "type": .string("command"), "command": .string(command), "timeout": .number(Double(Self.timeout))
            ])])])]),
            "state": .object([Self.key: .object(["enabled": .bool(true), "trusted_hash": .string(hash)])])
        ])
    }

    func isTrusted(_ report: JSONValue) -> Bool {
        entry(in: report)?["trustStatus"]?.stringValue == "trusted"
    }

    private func entry(in report: JSONValue) -> JSONValue? {
        let rows: [JSONValue] = report["data"]?.arrayValue ?? []
        let hooks: [JSONValue] = rows.flatMap { $0["hooks"]?.arrayValue ?? [] }
        let matches = hooks.filter { hook in
            guard hook["source"]?.stringValue == "sessionFlags", hook["key"]?.stringValue == Self.key,
                  hook["eventName"]?.stringValue == "preToolUse", hook["command"]?.stringValue == command else { return false }
            return hook["matcher"]?.stringValue == Self.matcher && hook["enabled"]?.boolValue == true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
