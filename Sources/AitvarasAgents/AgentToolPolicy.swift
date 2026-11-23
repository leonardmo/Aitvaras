import Foundation
import AitvarasCore

/// Shared by enforcement, persistent grants and presentation. Labels never classify a tool.
public enum AgentToolPolicy {
    public static func risk(_ tool: AgentTool) -> ActionRisk {
        if isCommandExecution(tool) { return .confirmable }
        if tool.name == "ToolSearch" || serviceRead(tool) || isMCPTool(tool) && tool.providerReportsReadOnly { return .read }
        return switch tool.name.lowercased() {
        case "read", "glob", "grep", "list", "ls", "todoread", "websearch", "webfetch", "enterplanmode", "exitplanmode", "askuserquestion", "question": .read
        case "write", "edit", "multiedit", "notebookedit": .reversibleWrite
        default: .confirmable
        }
    }
    public static func forbidden(_ tool: AgentTool) -> Bool {
        let name = tool.name.lowercased()
        if name.contains("mail") || name.contains("calendar") || name.contains("reminder")
            || (isMCPTool(tool) && ["outlook", "smtp", "eventkit"].contains(where: name.contains)) { return !serviceRead(tool) }
        if isCommandExecution(tool) {
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
    public static func isMCPTool(_ tool: AgentTool) -> Bool {
        tool.name.hasPrefix("mcp__")
    }

    public static func isGatewayTool(_ tool: AgentTool) -> Bool {
        tool.name.hasPrefix("mcp__aitvaras__")
    }

    /// Recognizes a limited set of effects in the request. Sandbox policy
    /// still applies to opaque scripts and effects shell syntax cannot reveal.
    public static func criticalApprovalReason(_ tool: AgentTool) -> String? {
        if isMCPTool(tool) {
            let name = tool.name.components(separatedBy: "__").last ?? ""
            return criticalMCPApprovalReason(toolName: name)
        }
        guard isCommandExecution(tool) else { return nil }
        if tool.input["dangerouslyDisableSandbox"]?.boolValue == true
            || tool.input["aitvarasWorkspaceApproval"]?.boolValue == true {
            return "This command requests access outside the workspace sandbox."
        }
        let command = tool.input["command"]?.stringValue
            ?? tool.input["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ")
        guard let command else { return nil }
        for words in commandSegments(AgentActionPresentation.displayCommand(command)) {
            let invocation = words.drop(while: { $0.contains("=") || ["env", "command", "sudo"].contains($0) })
            guard let command = invocation.first?.split(separator: "/").last else { continue }
            let arguments = invocation.dropFirst()
            if (command == "rm" && arguments.contains(where: {
                $0 == "--recursive" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.lowercased().contains("r"))
            })) || (command == "find" && arguments.contains("-delete")) {
                return "This command can recursively delete files."
            }
            if command == "gh", let subcommand = arguments.first {
                let action = arguments.dropFirst().first
                let deletesViaAPI = subcommand == "api" && (arguments.contains("--method=DELETE")
                    || arguments.contains("-XDELETE")
                    || zip(arguments, arguments.dropFirst()).contains { option, value in
                        ["--method", "-X"].contains(option) && value == "DELETE"
                    })
                if deletesViaAPI || (["repo", "release"].contains(subcommand) && action == "delete")
                    || (subcommand == "repo" && action == "archive") {
                    return "This command can delete or archive data on GitHub."
                }
            }
            if command == "git" {
                let subcommand = gitInvocation(arguments)
                let options = subcommand.dropFirst().prefix(while: { $0 != "--" })
                let dryRun = options.contains("--dry-run") || options.contains(where: {
                    $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("n")
                })
                if subcommand.first == "clean" && !dryRun || subcommand.first == "reset" && options.contains("--hard") {
                    return "This command can discard local changes."
                }
                if subcommand.first == "push", !dryRun, subcommand.dropFirst().contains(where: {
                    let ref = $0.split(separator: ":").last?.split(separator: "/").last ?? ""
                    return ["main", "master", "production"].contains(ref) || ["--force", "--mirror", "--delete", "-f"].contains($0)
                        || $0.hasPrefix("--force-with-lease")
                }) {
                    return "This push targets a protected branch or can rewrite remote history."
                }
            }
        }
        return nil
    }

    private static func gitInvocation(_ arguments: ArraySlice<String>) -> ArraySlice<String> {
        var arguments = arguments
        let optionsWithValue = ["-C", "-c", "--config-env", "--git-dir", "--namespace", "--work-tree", "--super-prefix"]
        while let argument = arguments.first, argument.hasPrefix("-") {
            arguments = arguments.dropFirst(optionsWithValue.contains(argument) ? 2 : 1)
        }
        return arguments
    }

    public static func criticalMCPApprovalReason(toolName: String) -> String? {
        let words = toolNameWords(toolName)
        let readVerbs: Set<Substring> = ["get", "list", "read", "search", "find", "fetch", "view"]
        let deleteVerbs: Set<Substring> = ["delete", "remove", "purge", "destroy", "truncate"]
        let outboundVerbs: Set<Substring> = ["send", "reply", "forward", "post", "publish", "share"]
        let deploymentVerbs: Set<Substring> = ["deploy", "promote", "rollback"]
        let accessVerbs: Set<Substring> = ["grant", "revoke", "rotate", "reset", "set", "change", "update"]
        let accessObjects: Set<Substring> = ["access", "permission", "permissions", "credential", "credentials",
                                               "password", "token", "apikey"]
        let actionVerbs = readVerbs.union(deleteVerbs).union(outboundVerbs).union(deploymentVerbs)
        if let action = words.first(where: actionVerbs.contains) {
            if deleteVerbs.contains(action) { return "This tool can delete or remove data." }
            if outboundVerbs.contains(action) { return "This tool can send or publish data." }
            if deploymentVerbs.contains(action) { return "This tool can change a deployment." }
        }
        if words.contains(where: accessVerbs.contains), words.contains(where: accessObjects.contains) {
            return "This tool can change permissions or credentials."
        }
        return nil
    }

    static func isRoutineMCPTool(_ tool: AgentTool) -> Bool {
        let toolName = tool.name.components(separatedBy: "__").last ?? ""
        return tool.providerReportsReadOnly || isRoutineMCPTool(toolName: toolName)
    }

    public static func isRoutineMCPTool(toolName: String) -> Bool {
        guard let verb = toolNameWords(toolName).first else { return false }
        return ["get", "list", "read", "search", "find", "fetch", "view", "lookup", "check",
                "create", "add", "edit", "update", "comment"].contains(verb)
    }

    private static func toolNameWords(_ name: String) -> [Substring] {
        name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression)
            .lowercased().split { !$0.isLetter && !$0.isNumber }
    }

    private static func commandSegments(_ command: String) -> [[String]] {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var comment = false
        for character in command {
            if comment {
                if character != "\n" { continue }
                comment = false
            }
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "#", word.isEmpty {
                comment = true
            } else if ";|&()\n".contains(character) {
                if !word.isEmpty { words.append(word); word = "" }
                if !words.isEmpty { segments.append(words); words = [] }
            } else if character.isWhitespace {
                if !word.isEmpty { words.append(word); word = "" }
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { words.append(word) }
        if !words.isEmpty { segments.append(words) }
        return segments
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
