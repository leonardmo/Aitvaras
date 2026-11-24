import Foundation
import AitvarasCore

public struct SettingsProposalSource: Sendable, Codable, Equatable {
    public let projectID: UUID?
    public let chatID: UUID?
    public let channel: String

    public init(projectID: UUID? = nil, chatID: UUID? = nil, channel: String) {
        self.projectID = projectID
        self.chatID = chatID
        self.channel = channel
    }
}

public struct SettingsValueChange: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let before: JSONValue
    public let after: JSONValue

    public init(id: String, before: JSONValue, after: JSONValue) {
        self.id = id
        self.before = before
        self.after = after
    }
}

/// Agent-supplied definitions contain only literals and slots for values the
/// user will enter later. Secret references are allocated by the app.
public struct SettingsMCPDraft: Sendable, Codable, Equatable {
    public enum Transport: String, CaseIterable, Sendable, Codable { case https, stdio }
    public enum Authentication: String, CaseIterable, Sendable, Codable { case none, oauth, header }
    public var name: String
    public var label: String
    public var transport: Transport
    public var auth: Authentication
    public var url: String?
    public var command: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var headers: [String: String]
    public var secretEnvironment: [String]
    public var secretHeaders: [String]
    public var global: Bool

    public init(name: String, label: String, transport: Transport = .https, auth: Authentication = .oauth,
                url: String? = nil, command: String? = nil, arguments: [String] = [],
                environment: [String: String] = [:], headers: [String: String] = [:],
                secretEnvironment: [String] = [], secretHeaders: [String] = [], global: Bool = false) {
        self.name = name; self.label = label; self.transport = transport; self.auth = auth
        self.url = url; self.command = command; self.arguments = arguments
        self.environment = environment; self.headers = headers
        self.secretEnvironment = secretEnvironment; self.secretHeaders = secretHeaders; self.global = global
    }

    public mutating func validate() throws {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters: ClosedRange<UInt8> = 97...122
        guard name.utf8.count <= 64, let first = name.utf8.first, letters.contains(first),
              name.utf8.allSatisfy({ letters.contains($0) || (48...57).contains($0) || $0 == 95 }),
              !label.isEmpty, label.utf8.count <= 80, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              arguments.count <= 32, environment.count + secretEnvironment.count <= 16,
              headers.count + secretHeaders.count <= 16,
              Set(secretEnvironment).count == secretEnvironment.count,
              Set(secretHeaders.map { $0.lowercased() }).count == secretHeaders.count,
              Set(secretEnvironment).isDisjoint(with: environment.keys),
              Set(secretHeaders.map { $0.lowercased() }).isDisjoint(with: headers.keys.map { $0.lowercased() }),
              environment.keys.allSatisfy({ !Self.credentialField($0) }),
              headers.keys.allSatisfy({ !Self.credentialField($0) }),
              (arguments + Array(environment.values) + Array(headers.values)).allSatisfy({
                  $0.utf8.count <= 2_048 && !Self.credentialLiteral($0)
              }) else { throw SettingsToolError.invalidDraft }

        switch transport {
        case .https:
            guard let url, let endpoint = URLComponents(string: url), endpoint.scheme == "https",
                  endpoint.host?.isEmpty == false, endpoint.query == nil,
                  command == nil, arguments.isEmpty, environment.isEmpty, secretEnvironment.isEmpty
            else { throw SettingsToolError.invalidDraft }
            switch auth {
            case .oauth:
                guard headers.isEmpty, secretHeaders.isEmpty else { throw SettingsToolError.invalidDraft }
            case .header:
                guard headers.isEmpty, secretHeaders.count == 1 else { throw SettingsToolError.invalidDraft }
            case .none: break
            }
        case .stdio:
            guard auth == .none, command?.isEmpty == false, url == nil, headers.isEmpty, secretHeaders.isEmpty,
                  command.map({ !Self.credentialLiteral($0) }) == true else { throw SettingsToolError.invalidDraft }
        }
        try server(secretReference: { _ in "agent.mcp.00000000-0000-4000-8000-000000000000" }).validate()
    }

    public func server(secretReference: (String) throws -> String) throws -> AgentMCPServer {
        var env = environment.mapValues(AgentMCPValue.literal)
        for key in secretEnvironment { env[key] = .secretReference(try secretReference(key)) }
        var requestHeaders = headers.mapValues(AgentMCPValue.literal)
        for key in secretHeaders { requestHeaders[key] = .secretReference(try secretReference(key)) }
        return .init(transport: transport == .stdio ? .stdio : .http, command: command, args: arguments,
                     env: env, url: url, headers: requestHeaders)
    }

    private static func credentialField(_ text: String) -> Bool {
        let compact = text.lowercased().filter(\.isLetter)
        return ["auth", "token", "key", "secret", "password", "credential", "cookie"].contains { compact.contains($0) }
    }

    private static func credentialLiteral(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["bearer ", "basic ", "-----begin ", "token=", "api_key=", "password=", "secret="].contains { lower.contains($0) }
    }
}

public enum SettingsToolError: LocalizedError, Sendable, Equatable {
    case invalidArguments, unavailable, invalidDraft, userOnly, invalidValue, stale, rateLimited, rejected
    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "Provide a setting ID and a valid value from settings_read."
        case .unavailable: "This setting or project is unavailable to this session."
        case .invalidDraft: "Check the server definition and use secret slots for credentials."
        case .userOnly: "Use settings_open or the dedicated setup form. This setting cannot be changed through a value proposal."
        case .invalidValue: "Choose a value allowed by settings_read."
        case .stale: "A setting changed after this request. Read its current value and submit a new proposal."
        case .rateLimited: "Review the existing setup requests before making more proposals."
        case .rejected: "This proposal was already rejected. Ask the user before suggesting another value."
        }
    }
}

public enum SettingsAgentTools {
    public static let definitions: [ToolDefinition] = [
        tool("read", "Discover stable settings IDs, allowed values and review requirements. Supply id to read one setting. Credentials are never returned.",
             fields: ["id": .object(["type": .string("string")])]),
        tool("propose", "Queue a before/after card for the user. No setting changes until the user approves. Use settings read first.",
             fields: ["changes": .object(["type": .string("object")]), "reason": .object(["type": .string("string")])],
             required: ["changes", "reason"]),
        tool("open", "Open a setting's home in Aitvaras when the user needs its dedicated editor.",
             fields: ["id": .object(["type": .string("string")])], required: ["id"]),
        tool("connections_propose", "Draft an MCP server for review. Use this project by default. Do not include credentials. Use secretEnvironment or secretHeaders to request secure input. Known servers are linear and notion.",
             fields: [
                "catalog": .object(["type": .string("string"), "enum": .array([.string("linear"), .string("notion")])]),
                "draft": .object(["type": .string("object"),
                    "required": .array(["name", "label", "transport", "auth"].map(JSONValue.string)),
                    "properties": .object([
                        "name": .object(["type": .string("string")]), "label": .object(["type": .string("string")]),
                        "transport": .object(["type": .string("string"), "enum": .array(["https", "stdio"].map(JSONValue.string))]),
                        "auth": .object(["type": .string("string"), "enum": .array(["none", "oauth", "header"].map(JSONValue.string))]),
                        "url": .object(["type": .string("string")]), "command": .object(["type": .string("string")]),
                        "arguments": strings, "environment": .object(["type": .string("object")]),
                        "headers": .object(["type": .string("object")]), "secretEnvironment": strings,
                        "secretHeaders": strings, "global": .object(["type": .string("boolean")])
                    ]), "additionalProperties": .bool(false)]),
                "reason": .object(["type": .string("string")])
             ], required: ["reason"])
    ]

    private static let strings: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")])])
    private static func tool(_ name: String, _ description: String, fields: [String: JSONValue],
                             required: [String] = []) -> ToolDefinition {
        .init(name: name, description: description, parametersJSON: JSONValue.object([
            "type": .string("object"), "properties": .object(fields),
            "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)
        ]).jsonString, risk: .read)
    }
}

public struct SettingsProposal: Sendable, Codable, Equatable, Identifiable {
    public enum Status: String, Sendable, Codable { case waiting, installed, applied, rejected, undone }
    public let id: UUID
    public let source: SettingsProposalSource
    public let reason: String
    public let createdAt: Date
    public var changes: [SettingsValueChange]
    public var server: SettingsMCPDraft?
    public var serverAccountID: UUID?
    public var appliedChanges: [SettingsValueChange]
    public var status: Status

    public init(id: UUID = UUID(), source: SettingsProposalSource, reason: String, createdAt: Date = .now,
                changes: [SettingsValueChange] = [], server: SettingsMCPDraft? = nil) {
        self.id = id; self.source = source; self.reason = reason; self.createdAt = createdAt
        self.changes = changes; self.server = server; self.appliedChanges = []; self.status = .waiting
    }

    public var isSensitive: Bool {
        server != nil || changes.contains { SettingsRegistry[$0.id]?.risk == .sensitive }
    }
}

extension SettingsMCPDraft {
    public static func catalog(_ name: String) -> Self? {
        switch name {
        case "linear": .init(name: "linear", label: "Linear", url: "https://mcp.linear.app/mcp")
        case "notion": .init(name: "notion", label: "Notion", url: "https://mcp.notion.com/mcp")
        default: nil
        }
    }

    public static func decode(_ value: JSONValue) throws -> Self {
        guard let fields = value.objectValue,
              Set(fields.keys).isSubset(of: ["name", "label", "transport", "auth", "url", "command",
                    "arguments", "environment", "headers", "secretEnvironment", "secretHeaders", "global"])
        else { throw SettingsToolError.invalidDraft }
        let defaults: [String: JSONValue] = ["arguments": .array([]), "environment": .object([:]),
            "headers": .object([:]), "secretEnvironment": .array([]), "secretHeaders": .array([]), "global": .bool(false)]
        let merged = defaults.merging(fields) { _, value in value }
        var draft = try JSONDecoder().decode(Self.self, from: Data(JSONValue.object(merged).jsonString.utf8))
        try draft.validate()
        return draft
    }
}
