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
            detail = command
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
