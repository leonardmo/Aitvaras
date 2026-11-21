import Foundation
import CryptoKit

/// Fixed diagnostics only: configuration, URLs and credential values never enter errors.
public enum AgentMCPError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidName, invalidApproval, invalidRepository
    case nameCollision, secretUnavailable, runtimeFile, auditFailed
}

/// Literals are non-secret configuration. Credentials are profile Keychain account names.
/// This type never holds a value obtained from the secret resolver.
public enum AgentMCPValue: Sendable, Equatable, Codable {
    case literal(String)
    case secretReference(String)

    public static func validateSecretReference(_ key: String) throws {
        let prefix = "agent.mcp."
        guard key.hasPrefix(prefix), key.utf8.count == prefix.utf8.count + 36,
              UUID(uuidString: String(key.dropFirst(prefix.count))) != nil else { throw AgentMCPError.invalidConfiguration }
    }
    public var secretKey: String? { if case .secretReference(let key) = self { key } else { nil } }
    private enum CodingKeys: String, CodingKey { case value, secretKey }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.value) != c.contains(.secretKey) else { throw AgentMCPError.invalidConfiguration }
        if c.contains(.value) { self = .literal(try c.decode(String.self, forKey: .value)) }
        else {
            let key = try c.decode(String.self, forKey: .secretKey)
            try Self.validateSecretReference(key); self = .secretReference(key)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let value): try c.encode(value, forKey: .value)
        case .secretReference(let key): try Self.validateSecretReference(key); try c.encode(key, forKey: .secretKey)
        }
    }
}

public enum AgentPermissionSource: String, Sendable, Codable { case repo, aitvaras }

public struct AgentMCPServer: Sendable, Equatable, Codable {
    public enum Transport: String, Sendable, Codable { case stdio, http, sse }
    public enum Management: String, Sendable, Codable { case gatewayOAuth, gatewayStaticHeader }
    public let transport: Transport
    public let command: String?
    public let args: [String]
    public let env: [String: AgentMCPValue]
    public let url: String?
    public let headers: [String: AgentMCPValue]
    /// Absent in native definitions, including every D34 definition.
    public let management: Management?

    public init(transport: Transport = .stdio, command: String? = nil, args: [String] = [],
                env: [String: AgentMCPValue] = [:], url: String? = nil, headers: [String: AgentMCPValue] = [:],
                management: Management? = nil) {
        self.transport = transport; self.command = command; self.args = args
        self.env = env; self.url = url; self.headers = headers
        self.management = management
    }

    public func validate() throws {
        guard args.count <= 256, env.count <= 256, headers.count <= 256,
              args.allSatisfy({ Self.validText($0) }),
              env.allSatisfy({ key, value in Self.validText(key, empty: false) && !key.contains("=") && Self.valid(value) }),
              headers.allSatisfy({ key, value in
                  !key.isEmpty && key.utf8.allSatisfy { (33...126).contains($0) && $0 != 58 }
                      && Self.valid(value) && !Self.text(value).contains(where: { $0.isNewline })
              }) else { throw AgentMCPError.invalidConfiguration }
        switch transport {
        case .stdio:
            guard let command, Self.validText(command, empty: false), url == nil, headers.isEmpty else {
                throw AgentMCPError.invalidConfiguration
            }
        case .http, .sse:
            guard command == nil, args.isEmpty, env.isEmpty, let url, Self.validText(url, empty: false),
                  let parts = URLComponents(string: url), ["http", "https"].contains(parts.scheme),
                  parts.host?.isEmpty == false, parts.user == nil, parts.password == nil, parts.fragment == nil else {
                throw AgentMCPError.invalidConfiguration
            }
        }
        if management != nil {
            guard transport == .http, headers.isEmpty, let url,
                  let endpoint = URLComponents(string: url), endpoint.scheme == "https",
                  endpoint.query == nil, url.utf8.count <= 4096 else { throw AgentMCPError.invalidConfiguration }
        }
    }

    /// Sorted JSON includes all definition fields, including non-secret literals.
    /// Keychain references hash by account name; resolved credentials never participate.
    public func fingerprint() throws -> String {
        try validate()
        return SHA256.hash(data: Data(try AgentMCPConfiguration.encode(self).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func validText(_ text: String, empty: Bool = true) -> Bool {
        (empty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && text.utf8.count <= 32_768 && !text.contains("\0")
    }
    private static func text(_ value: AgentMCPValue) -> String {
        switch value { case .literal(let text), .secretReference(let text): text }
    }
    private static func valid(_ value: AgentMCPValue) -> Bool {
        switch value {
        case .literal(let text): validText(text)
        case .secretReference(let key): (try? AgentMCPValue.validateSecretReference(key)) != nil
        }
    }
}

public enum AgentMCPConfiguration {
    public static let maximumBytes = 1_048_576
    public static func validateName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty, name.utf8.count <= 200, name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw AgentMCPError.invalidName
        }
    }
    public static func validate(_ servers: [String: AgentMCPServer]) throws {
        guard servers.count <= 128 else { throw AgentMCPError.invalidConfiguration }
        for (name, server) in servers { try validateName(name); try server.validate() }
        guard try encode(servers).utf8.count <= maximumBytes else { throw AgentMCPError.invalidConfiguration }
    }
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    public static func decodeServers(_ json: String) throws -> [String: AgentMCPServer] {
        guard json.utf8.count <= maximumBytes else { throw AgentMCPError.invalidConfiguration }
        do {
            let servers = try JSONDecoder().decode([String: AgentMCPServer].self, from: Data(json.utf8))
            try validate(servers)
            return servers
        } catch { throw AgentMCPError.invalidConfiguration }
    }
}
