import Foundation

/// Presentation limits apply only to transcript copies, never provider replies.
public enum AgentTranscriptContent {
    public static let maximumBytes = 32_768
    public static let truncation = "\n… [truncated]"

    public static func bounded(_ text: String, limit: Int = maximumBytes) -> String {
        guard text.utf8.count > limit else { return text }
        let budget = max(0, limit - truncation.utf8.count)
        var result = "", size = 0
        for character in text {
            let bytes = character.utf8.count
            guard size + bytes <= budget else { break }
            result.append(character); size += bytes
        }
        return result + truncation
    }

    static func append(_ delta: String, to text: String) -> String {
        guard !text.hasSuffix(truncation) else { return text }
        return bounded(text + bounded(delta))
    }

    static func bounded(_ value: JSONValue) -> JSONValue {
        if case .string(let text) = value { return .string(bounded(text)) }
        let text = value.jsonString
        return text.utf8.count <= maximumBytes ? value : .string(bounded(text))
    }

    /// Hide protocol envelopes; show the actual command, file, and result.
    public static func display(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .string(let text): return bounded(text)
        case .array(let values): return bounded(values.map(display).filter { !$0.isEmpty }.joined(separator: "\n"))
        case .object(let fields):
            if fields["type"]?.stringValue == "commandExecution", let exitCode = fields["exitCode"]?.int {
                let text = fields["aggregatedOutput"]?.stringValue ?? ""
                return bounded("Exit code: \(exitCode)" + (text.isEmpty ? "" : "\n" + text))
            }
            if let text = fields["aggregatedOutput"]?.stringValue { return bounded(text) }
            if fields["type"]?.stringValue == "text", let text = fields["text"]?.stringValue { return bounded(text) }
            let hidden: Set<String> = ["type", "id", "itemId", "threadId", "turnId", "startedAtMs", "completedAtMs", "status", "commandActions"]
            return bounded(fields.keys.sorted().filter { !hidden.contains($0) }.compactMap { key in
                let text = display(fields[key]!)
                return text.isEmpty ? nil : "\(key): \(text)"
            }.joined(separator: "\n"))
        default: return value.jsonString
        }
    }
}

/// Ephemeral Suggestion: the native request and its owner travel together.
/// Never restored from disk or executed through a connector.
public struct AgentApprovalSuggestion: Sendable, Equatable, Identifiable {
    public let chatID: UUID
    public let request: AgentRequest
    public var id: String { request.identity }
    public init(chatID: UUID, request: AgentRequest) { self.chatID = chatID; self.request = request }
}

extension AgentRequest {
    public var identity: String { "\(scope.runID.uuidString).\(id.encoded)" }
    public var presentation: AgentActionPresentation {
        switch kind {
        case .permission(let tool), .preToolUse(let tool): return AgentActionPresentation(tool: tool)
        case .permissions(let raw):
            let permissions = raw["permissions"] ?? .null
            var lines: [String] = []
            if permissions["network"]?["enabled"]?.boolValue == true { lines.append("Network access for this turn") }
            let files = permissions["fileSystem"] ?? .null
            for key in ["read", "write"] {
                for path in files[key]?.arrayValue ?? [] {
                    if let path = path.stringValue { lines.append("\(key.capitalized): \(path)") }
                }
            }
            for entry in files["entries"]?.arrayValue ?? [] {
                let path = entry["path"] ?? .null
                let location = path["path"]?.stringValue ?? path["pattern"]?.stringValue
                    ?? path["value"]?["kind"]?.stringValue ?? "requested location"
                lines.append("\((entry["access"]?.stringValue ?? "Access").capitalized): \(location)")
            }
            return .init(title: "Allow access for this turn?", detail: lines.isEmpty ? "Additional access requested" : lines.joined(separator: "\n"), reason: raw["reason"]?.stringValue)
        case .plan(let text): return .init(title: "Allow this plan?", detail: text)
        default: return .init(title: "Provider request", detail: "")
        }
    }
}

public struct AgentActionPresentation: Sendable, Equatable {
    public let title: String
    public let detail: String
    public let reason: String?
    public init(title: String, detail: String, reason: String? = nil) {
        self.title = title; self.detail = AgentTranscriptContent.bounded(detail)
        self.reason = reason.map { AgentTranscriptContent.bounded($0, limit: 2_048) }
    }
    public init(tool: AgentTool) {
        let input = tool.input
        let name = tool.name.lowercased()
        let command = input["command"]?.stringValue ?? input["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ")
        let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue
        let paths = input["changes"]?.arrayValue?.compactMap { $0["path"]?.stringValue } ?? []
        let title: String
        let detail: String
        if let command, !command.isEmpty {
            title = input["kind"]?.stringValue == "writeStdin" ? "Send input to command?" : "Run command?"
            detail = Self.displayCommand(command)
        } else if let root = input["grantRoot"]?.stringValue {
            title = "Allow file changes?"
            detail = (["Write access under \(root) for this session"] + paths).joined(separator: "\n")
        } else if let path {
            title = ["write", "edit", "multiedit", "notebookedit", "filechange"].contains(name) ? "Change file?" : "Read file?"
            detail = path
        } else if !paths.isEmpty {
            title = "Change files?"; detail = paths.joined(separator: "\n")
        } else {
            title = "Allow \(tool.name)?"
            detail = name == "filechange" ? "File changes requested; the provider did not supply paths." : AgentTranscriptContent.display(input)
        }
        self.init(title: title, detail: detail, reason: input["reason"]?.stringValue)
    }
}


extension AgentActionPresentation {
    /// Presentation only: never changes the command sent to the CLI or the input
    /// retained in the expanded tool row. Reject extra arguments and shell syntax
    /// outside one plain quoted -lc argument rather than guessing at shell parsing.
    public static func displayCommand(_ command: String) -> String {
        let pattern = #"^(?:/(?:usr/)?bin/)?(?:zsh|bash|sh) -lc (?:'([^']*)'|"([^"\\$`]*)")$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              match.range.length == command.utf16.count else { return command }
        for index in 1...2 {
            if let range = Range(match.range(at: index), in: command) { return String(command[range]) }
        }
        return command
    }

    public static func toolSummary(_ tool: AgentTool, finished: Bool, isError: Bool, completionUnconfirmed: Bool = false) -> String {
        let detail = AgentActionPresentation(tool: tool).detail.components(separatedBy: .newlines).first ?? ""
        if completionUnconfirmed { return detail.isEmpty ? "Ended without a result" : "Ended without a result: \(detail)" }
        let verbs: (String, String, String)
        switch tool.name.lowercased() {
        case "bash", "commandexecution": verbs = ("Running", "Ran", "Failed to run")
        case "read": verbs = ("Reading", "Read", "Failed to read")
        case "edit", "multiedit", "notebookedit", "filechange": verbs = ("Editing", "Edited", "Failed to edit")
        case "write": verbs = ("Writing", "Wrote", "Failed to write")
        default: verbs = ("Using \(tool.name)", "Used \(tool.name)", "Failed to use \(tool.name)")
        }
        let verb = finished ? (isError ? verbs.2 : verbs.1) : verbs.0
        return detail.isEmpty ? verb : "\(verb) \(detail)"
    }
}

extension AgentTranscriptEntry {
    public var presentationIdentifier: String {
        if kind == "tool", let payload = payloadJSON.flatMap(JSONValue.parse),
           payload["finished"]?.boolValue == true, payload["isError"]?.boolValue != true,
           payload["completionUnconfirmed"]?.boolValue != true {
            return "chat.tool.completed"
        }
        if kind == "importedHistory" { return "chat.importedHistory.\(id)" }
        if kind == "handover" { return "chat.handover.\(id)" }
        return "chat.entry.\(id)"
    }
}
