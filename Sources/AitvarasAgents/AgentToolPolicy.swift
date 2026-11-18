import Foundation
import AitvarasCore

/// Shared by enforcement, persistent grants and presentation. Labels never classify a tool.
public enum AgentToolPolicy {
    public static func risk(_ tool: AgentTool) -> ActionRisk {
        if isCommandExecution(tool) { return .confirmable }
        if tool.name == "ToolSearch" || serviceRead(tool) { return .read }
        return switch tool.name.lowercased() {
        case "read", "glob", "grep", "list", "ls", "todoread", "websearch", "webfetch", "enterplanmode", "exitplanmode", "askuserquestion", "question": .read
        case "write", "edit", "multiedit", "notebookedit": .reversibleWrite
        default: .confirmable
        }
    }
    public static func forbidden(_ tool: AgentTool) -> Bool {
        let name = tool.name.lowercased()
        if name.contains("mail") || name.contains("calendar") || name.contains("reminder") { return !serviceRead(tool) }
        if name == "bash" || name == "commandexecution" {
            let command = (tool.input["command"]?.stringValue ?? tool.input["command"]?.jsonString ?? "").lowercased()
            return ["sendmail", "smtp", "mail ", "mailx", "mailto:", "osascript"].contains { command.contains($0) }
        }
        return false
    }
    public static func isCommandExecution(_ tool: AgentTool) -> Bool {
        ["bash", "commandexecution", "shell", "exec_command", "executecommand", "run_command", "write_stdin"].contains(tool.name.lowercased())
            || tool.input["type"]?.stringValue?.lowercased() == "commandexecution"
            || tool.input["kind"]?.stringValue?.lowercased() == "commandexecution"
    }
    public static func grantEligible(_ tool: AgentTool) -> Bool {
        guard !forbidden(tool), !isCommandExecution(tool) else { return false }
        return !requiresExplicitMCPApproval(tool)
    }
    public static func requiresExplicitMCPApproval(_ tool: AgentTool) -> Bool {
        let name = tool.name.lowercased()
        return name.hasPrefix("mcp__") && ["send", "reply", "forward", "compose", "draft", "post", "publish"].contains { name.contains($0) }
    }
    public static func grantKey(provider: AgentProvider, tool: String, fingerprint: String? = nil) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !tool.isEmpty, tool.utf8.count <= 512, tool.unicodeScalars.allSatisfy(allowed.contains),
              grantEligible(.init(name: tool, input: .null)) else { throw AgentFailure.invalidRequest }
        let key = provider.rawValue + "." + tool
        if tool.hasPrefix("mcp__") {
            guard let fingerprint, fingerprint.utf8.count == 64,
                  fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AgentFailure.invalidRequest }
            return key + "@" + fingerprint
        }
        return key
    }
    public static func fingerprint(tool: String, servers: [String: String]) -> String? {
        // A wire name must identify one server; '__' in names can make two
        // prefixes match. Never guess which definition an approval belongs to.
        let matches = servers.keys.filter { tool.hasPrefix("mcp__" + $0 + "__") && tool.utf8.count > $0.utf8.count + 7 }
        guard matches.count == 1, let name = matches.first else { return nil }
        return servers[name]
    }
    public static func currentGrants(_ grants: Set<String>, servers: [String: String]) -> Set<String> {
        Set(grants.filter { grant in
            guard let separator = grant.firstIndex(of: "."), let provider = AgentProvider(rawValue: String(grant[..<separator])) else { return false }
            let tool = String(grant[grant.index(after: separator)...].split(separator: "@", maxSplits: 1).first ?? "")
            return (try? grantKey(provider: provider, tool: tool, fingerprint: fingerprint(tool: tool, servers: servers))) == grant
        })
    }
    public static func canAlwaysAllow(_ request: AgentRequest) -> Bool {
        guard case .permission(let tool) = request.kind, grantEligible(tool), request.scope.inputID != nil,
              let provider = request.scope.session?.provider else { return false }
        // Presentation without a launch snapshot checks only name eligibility.
        return (try? grantKey(provider: provider, tool: tool.name, fingerprint: String(repeating: "0", count: 64))) != nil
    }
    private static func serviceRead(_ tool: AgentTool) -> Bool {
        let names: Set<String> = ["mail.read", "mail.search", "mail.list", "mail.get",
            "mail.recent_messages", "mail.get_message", "mail.search_messages",
            "calendar.list", "calendar.read", "calendar.search", "calendar.list_events",
            "reminders.list", "reminders.read", "reminders.search", "reminders.list_reminders"]
        return names.contains(tool.name.lowercased())
    }
}
