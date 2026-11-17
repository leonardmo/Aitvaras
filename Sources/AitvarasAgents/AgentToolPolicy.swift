import Foundation
import AitvarasCore

/// Shared by enforcement, persistent grants and presentation. Labels never classify a tool.
public enum AgentToolPolicy {
    public static func risk(_ tool: AgentTool) -> ActionRisk {
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
    public static func grantKey(provider: AgentProvider, tool: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !tool.isEmpty, tool.utf8.count <= 512, tool.unicodeScalars.allSatisfy(allowed.contains) else { throw AgentFailure.invalidRequest }
        return provider.rawValue + "." + tool
    }
    public static func canAlwaysAllow(_ request: AgentRequest) -> Bool {
        guard case .permission(let tool) = request.kind, !forbidden(tool), request.scope.inputID != nil,
              let provider = request.scope.session?.provider else { return false }
        return (try? grantKey(provider: provider, tool: tool.name)) != nil
    }
    private static func serviceRead(_ tool: AgentTool) -> Bool {
        let names: Set<String> = ["mail.read", "mail.search", "mail.list", "mail.get",
            "mail.recent_messages", "mail.get_message", "mail.search_messages",
            "calendar.list", "calendar.read", "calendar.search", "calendar.list_events",
            "reminders.list", "reminders.read", "reminders.search", "reminders.list_reminders"]
        return names.contains(tool.name.lowercased())
    }
}
