import Foundation
import AitvarasCore

/// Declarative description of an HTTP API connector (D17): base URL, auth
/// scheme, endpoints exposed as typed tools, and polling triggers. Users
/// (or Aitvaras herself, drafting from API docs) write these as JSON — no
/// Swift required. Secrets are never in the manifest; it references
/// Keychain entries by key name.
public struct ConnectorManifest: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    /// e.g. "https://proxmox.local:8006" — no trailing slash needed.
    public var baseURL: String
    public var auth: Auth
    public var tools: [Tool]
    public var triggers: [Trigger]

    public init(id: String, displayName: String, baseURL: String, auth: Auth,
                tools: [Tool], triggers: [Trigger] = []) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.auth = auth
        self.tools = tools
        self.triggers = triggers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        auth = try c.decode(Auth.self, forKey: .auth)
        tools = try c.decode([Tool].self, forKey: .tools)
        triggers = try c.decodeIfPresent([Trigger].self, forKey: .triggers) ?? []
    }

    // MARK: Auth

    public struct Auth: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case bearer     // Authorization: Bearer <secret>
            case header     // <headerName>: [valuePrefix]<secret>   (e.g. Proxmox PVEAPIToken=…)
            case query      // ?<queryParam>=<secret>
            case basic      // Authorization: Basic base64(<secret>), secret is "user:pass"
            case none
        }

        public var type: Kind
        /// Keychain key holding the secret (all secrets live in the Keychain).
        public var keychainKey: String?
        /// For `.header`: the header to set.
        public var headerName: String?
        /// For `.header`: literal prefix before the secret, e.g. "PVEAPIToken=".
        public var valuePrefix: String?
        /// For `.query`: the query parameter name.
        public var queryParam: String?

        public init(type: Kind, keychainKey: String? = nil, headerName: String? = nil,
                    valuePrefix: String? = nil, queryParam: String? = nil) {
            self.type = type
            self.keychainKey = keychainKey
            self.headerName = headerName
            self.valuePrefix = valuePrefix
            self.queryParam = queryParam
        }
    }

    // MARK: Tools

    public struct Tool: Codable, Sendable, Equatable {
        public var name: String
        public var description: String
        /// HTTP method: GET, POST, PUT, PATCH, DELETE.
        public var method: String
        /// Path relative to baseURL; `{placeholders}` are filled from tool
        /// arguments. Leftover arguments become query parameters (GET/DELETE)
        /// or the JSON body (other methods, unless bodyTemplate is set).
        public var path: String
        /// JSON Schema for the tool arguments, passed straight to the model.
        public var parametersJSON: String
        public var risk: ActionRisk
        /// Optional raw body with `{placeholders}`; substituted values are
        /// JSON-string-escaped so templates stay valid JSON.
        public var bodyTemplate: String?

        public init(name: String, description: String, method: String, path: String,
                    parametersJSON: String, risk: ActionRisk, bodyTemplate: String? = nil) {
            self.name = name
            self.description = description
            self.method = method
            self.path = path
            self.parametersJSON = parametersJSON
            self.risk = risk
            self.bodyTemplate = bodyTemplate
        }
    }

    // MARK: Triggers

    /// A poll-and-watch automation: fetch `path` every `intervalSeconds`,
    /// extract the value at `watchPath` (dot notation, e.g. "result.0.status"),
    /// and emit a ConnectorEvent whenever it changes (D17).
    public struct Trigger: Codable, Sendable, Equatable {
        public var name: String
        public var method: String
        public var path: String
        public var intervalSeconds: Double
        public var watchPath: String
        /// Event title; supports {name}, {value}, {previous}.
        public var titleTemplate: String

        public init(name: String, method: String = "GET", path: String,
                    intervalSeconds: Double, watchPath: String, titleTemplate: String) {
            self.name = name
            self.method = method
            self.path = path
            self.intervalSeconds = intervalSeconds
            self.watchPath = watchPath
            self.titleTemplate = titleTemplate
        }
    }
}

/// Pure request-building / JSON-navigation machinery behind
/// GenericHTTPConnector — separated out so it is unit-testable without
/// any network (D17).
enum ManifestEngine {

    // MARK: Placeholder substitution

    /// Replaces `{key}` occurrences with values from `args`.
    /// - `encoder` transforms each substituted value (percent-encoding for
    ///   paths, JSON escaping for body templates, identity otherwise).
    /// - Returns the substituted text and the set of consumed keys, so the
    ///   caller knows which arguments are "left over".
    static func substitute(
        _ template: String,
        args: [String: String],
        encoder: (String) -> String = { $0 }
    ) -> (text: String, used: Set<String>) {
        var result = template
        var used: Set<String> = []
        for (key, value) in args {
            let placeholder = "{\(key)}"
            guard result.contains(placeholder) else { continue }
            result = result.replacingOccurrences(of: placeholder, with: encoder(value))
            used.insert(key)
        }
        return (result, used)
    }

    static func pathEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    static func jsonEscaped(_ value: String) -> String {
        JSONText.escape(value)
    }

    // MARK: Request building

    /// Builds the URLRequest for a tool call: path placeholders, leftover
    /// args as query/body, auth applied. `secret` is the raw Keychain value
    /// (nil when auth.type == .none).
    static func buildRequest(
        baseURL: String,
        auth: ConnectorManifest.Auth,
        method: String,
        path: String,
        args: [String: String],
        bodyTemplate: String?,
        secret: String?
    ) throws -> URLRequest {
        let (filledPath, usedInPath) = substitute(path, args: args, encoder: pathEncoded)
        var leftover = args.filter { !usedInPath.contains($0.key) }

        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: base + filledPath) else {
            throw ConnectorError("Invalid URL: \(base + filledPath)")
        }

        let httpMethod = method.uppercased()
        var body: Data?
        var contentType: String?

        if let bodyTemplate {
            let (filledBody, usedInBody) = substitute(bodyTemplate, args: leftover, encoder: jsonEscaped)
            for key in usedInBody { leftover.removeValue(forKey: key) }
            body = Data(filledBody.utf8)
            contentType = "application/json"
        }

        if !leftover.isEmpty {
            if httpMethod == "GET" || httpMethod == "DELETE" || body != nil {
                // Query parameters (also for extra args not consumed by a body template).
                var items = components.queryItems ?? []
                items.append(contentsOf: leftover.sorted { $0.key < $1.key }
                    .map { URLQueryItem(name: $0.key, value: $0.value) })
                components.queryItems = items
            } else {
                // JSON body from the leftover arguments.
                let object = leftover as [String: Any]
                body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                contentType = "application/json"
            }
        }

        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        try applyAuth(auth, secret: secret, components: &components, headers: &headers)

        guard let url = components.url else {
            throw ConnectorError("Invalid URL after substitution: \(base + filledPath)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Applies the manifest's auth scheme to the outgoing request parts.
    static func applyAuth(
        _ auth: ConnectorManifest.Auth,
        secret: String?,
        components: inout URLComponents,
        headers: inout [String: String]
    ) throws {
        switch auth.type {
        case .none:
            return
        case .bearer:
            headers["Authorization"] = "Bearer \(try requiredSecret(secret, auth: auth))"
        case .header:
            guard let name = auth.headerName, !name.isEmpty else {
                throw ConnectorError("Auth type 'header' requires 'headerName' in the manifest.")
            }
            headers[name] = (auth.valuePrefix ?? "") + (try requiredSecret(secret, auth: auth))
        case .query:
            guard let param = auth.queryParam, !param.isEmpty else {
                throw ConnectorError("Auth type 'query' requires 'queryParam' in the manifest.")
            }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: param, value: try requiredSecret(secret, auth: auth)))
            components.queryItems = items
        case .basic:
            let userPass = try requiredSecret(secret, auth: auth)
            headers["Authorization"] = "Basic " + Data(userPass.utf8).base64EncodedString()
        }
    }

    private static func requiredSecret(_ secret: String?, auth: ConnectorManifest.Auth) throws -> String {
        guard let secret, !secret.isEmpty else {
            throw ConnectorError("Missing secret — add Keychain entry '\(auth.keychainKey ?? "?")' in Settings → Connectors.")
        }
        return secret
    }

    // MARK: watchPath navigation

    /// Walks dot notation into parsed JSON: dictionary keys and integer
    /// array indices, e.g. "result.0.status". Returns a stable string
    /// rendering of the value found, or nil when the path does not resolve.
    static func value(at dotPath: String, in json: Any) -> String? {
        var current: Any = json
        for component in dotPath.split(separator: ".") {
            if let dict = current as? [String: Any] {
                guard let next = dict[String(component)] else { return nil }
                current = next
            } else if let array = current as? [Any], let index = Int(component),
                      array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        switch current {
        case let s as String:
            return s
        case let n as NSNumber:
            // Distinguish booleans from numbers (both are NSNumber).
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        case is NSNull:
            return "null"
        default:
            guard JSONSerialization.isValidJSONObject(current),
                  let data = try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}
