import Foundation
import AitvarasCore
import AitvarasStore

/// A constrained Home Assistant REST adapter. Connection details remain in
/// local state/Keychain; the repository contains only generic capabilities.
///
/// Unlike the generic manifest runner, this adapter can turn the very large
/// `/api/states` response into a bounded, searchable inventory and can discard
/// service-call response bodies instead of feeding household state back to the
/// model unnecessarily.
public actor HomeAssistantConnector: Connector {
    public nonisolated let id = "homeassistant"
    public nonisolated let displayName = "Home Assistant"
    public nonisolated let tools: [ToolDefinition]

    private static let statesResponseByteLimit = 4 * 1_024 * 1_024
    private static let smallResponseByteLimit = 256 * 1_024
    private static let maximumToolOutputCharacters = 12_000
    private static let healthyProbeInterval: TimeInterval = 5 * 60
    private static let transientFailureRetryInterval: TimeInterval = 60

    private let baseURL: String
    private let tokenProvider: @Sendable () throws -> String?
    private let session: URLSession
    private var healthCache: (value: ConnectorHealth, retryAfter: Date?)?

    public init(
        baseURL: String,
        keychain: KeychainStore,
        session: URLSession = ConnectorHTTPSession.make()
    ) throws {
        let normalized = try HomeAssistantEndpoint.normalizedBaseURL(baseURL)
        self.baseURL = normalized
        self.session = session
        self.tokenProvider = {
            try keychain.get(BundledManifests.homeAssistantTokenKey)
        }
        self.tools = BundledManifests.homeAssistant(baseURL: normalized).tools.map {
            ToolDefinition(
                name: $0.name, description: $0.description,
                parametersJSON: $0.parametersJSON, risk: $0.risk)
        }
    }

    /// Test seam that avoids touching the real Keychain.
    init(
        baseURL: String,
        tokenProvider: @escaping @Sendable () throws -> String?,
        session: URLSession
    ) throws {
        let normalized = try HomeAssistantEndpoint.normalizedBaseURL(baseURL)
        self.baseURL = normalized
        self.session = session
        self.tokenProvider = tokenProvider
        self.tools = BundledManifests.homeAssistant(baseURL: normalized).tools.map {
            ToolDefinition(
                name: $0.name, description: $0.description,
                parametersJSON: $0.parametersJSON, risk: $0.risk)
        }
    }

    public func health() async -> ConnectorHealth {
        if let healthCache,
           healthCache.retryAfter == nil || healthCache.retryAfter! > Date() {
            return healthCache.value
        }

        let result: ConnectorHealth
        let retryAfter: Date?
        do {
            guard let token = try configuredToken() else {
                result = .needsAuthentication(
                    message: "Home Assistant token missing—reconnect it in Connections.")
                retryAfter = nil
                healthCache = (result, retryAfter)
                return result
            }
            try await Self.probe(baseURL: baseURL, token: token, session: session)
            result = .ready
            retryAfter = Date().addingTimeInterval(Self.healthyProbeInterval)
        } catch HomeAssistantRequestError.authenticationRejected {
            result = .needsAuthentication(
                message: "Home Assistant rejected the token—create a new long-lived access token and reconnect.")
            // A 15-second UI refresh must not repeatedly submit a bad token:
            // Home Assistant can turn those attempts into a persistent IP ban.
            retryAfter = nil
        } catch HomeAssistantRequestError.accessForbidden {
            result = .error(
                message: "Home Assistant refused access. Check for an inactive/local-only user, reverse-proxy restriction, or IP ban, then reconnect.")
            retryAfter = nil
        } catch {
            result = .error(message: error.localizedDescription)
            retryAfter = Date().addingTimeInterval(Self.transientFailureRetryInterval)
        }
        healthCache = (result, retryAfter)
        return result
    }

    /// Verifies a proposed URL/token before either is persisted.
    public static func verifyConnection(
        baseURL: String,
        token: String,
        session: URLSession = ConnectorHTTPSession.make()
    ) async throws -> String {
        let normalized = try HomeAssistantEndpoint.normalizedBaseURL(baseURL)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, cleanToken.utf8.count <= 16 * 1_024 else {
            throw ConnectorError("Enter a valid Home Assistant long-lived access token.")
        }
        try await probe(baseURL: normalized, token: cleanToken, session: session)
        return normalized
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        guard tools.contains(where: { $0.name == toolName }) else {
            throw ConnectorError("Home Assistant has no tool named '\(toolName)'.")
        }
        guard let token = try configuredToken() else {
            throw ConnectorError("Home Assistant token missing—reconnect it in Connections.")
        }
        let args = try ToolArgs(json: argumentsJSON)
        switch toolName {
        case "ha_states":
            try args.requireOnly([])
            return try await inventory(token: token)
        case "search_entities":
            try args.requireOnly(["query", "domain", "state", "limit"])
            return try await search(args: args, token: token)
        case "ha_entity":
            try args.requireOnly(["entity_id"])
            let entityID = try Self.validEntityID(args.requiredString("entity_id"))
            let entity = try await fetchEntity(entityID, token: token)
            return entity.rendered(redacting: token)
        case "light_off":
            try args.requireOnly(["entity_id", "transition_seconds"])
            return try await setLight(on: false, args: args, token: token)
        case "light_on":
            try args.requireOnly(["entity_id", "brightness_pct", "transition_seconds"])
            return try await setLight(on: true, args: args, token: token)
        default:
            throw ConnectorError("Home Assistant has no tool named '\(toolName)'.")
        }
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        AsyncStream { $0.finish() }
    }

    // MARK: Reads

    private func inventory(token: String) async throws -> String {
        let states = try await fetchStates(token: token)
        let grouped = Dictionary(grouping: states, by: \.domain)
        let counts = grouped.keys.sorted().map { "\($0): \(grouped[$0]?.count ?? 0)" }
        let commonDevices = ["light", "switch", "climate", "cover", "media_player"]
            .compactMap { domain -> String? in
                guard let count = grouped[domain]?.count, count > 0 else { return nil }
                return "\(domain): \(count)"
            }
        let headline = "Home Assistant has \(states.count) entities across \(grouped.count) domains."
        let useful = commonDevices.isEmpty
            ? "No common device domains were found."
            : "Common device domains: " + commonDevices.joined(separator: ", ") + "."
        return truncated(
            headline + "\n" + useful + "\nAll domain counts: "
                + counts.joined(separator: ", ")
                + "\nUse search_entities with a name or domain before acting.",
            limit: Self.maximumToolOutputCharacters)
    }

    private func search(args: ToolArgs, token: String) async throws -> String {
        let query = args.string("query") ?? ""
        let domain = try Self.validOptionalDomain(args.string("domain"))
        let desiredState = args.string("state")?.lowercased()
        let limit = args.int("limit") ?? 20
        guard (1...50).contains(limit) else {
            throw ConnectorError("'limit' must be between 1 and 50.")
        }

        let normalizedQuery = Self.normalized(query)
        let matches = try await fetchStates(token: token).filter { entity in
            (domain == nil || entity.domain == domain)
                && (desiredState == nil || entity.state.lowercased() == desiredState)
                && (normalizedQuery.isEmpty
                    || Self.normalized(entity.entityID).contains(normalizedQuery)
                    || Self.normalized(entity.friendlyName ?? "").contains(normalizedQuery))
        }.sorted { lhs, rhs in
            let lhsScore = Self.searchScore(lhs, query: normalizedQuery)
            let rhsScore = Self.searchScore(rhs, query: normalizedQuery)
            return lhsScore == rhsScore ? lhs.entityID < rhs.entityID : lhsScore < rhsScore
        }

        guard !matches.isEmpty else {
            return "No Home Assistant entities matched. Try a shorter name or a domain such as light or sensor."
        }
        let shown = matches.prefix(limit).map { $0.rendered(redacting: token) }
        let suffix = matches.count > shown.count
            ? "\n…\(matches.count - shown.count) more matches; narrow the query." : ""
        return truncated(
            "Found \(matches.count) matching entities:\n" + shown.joined(separator: "\n") + suffix,
            limit: Self.maximumToolOutputCharacters)
    }

    private func fetchStates(token: String) async throws -> [HomeAssistantEntity] {
        let data = try await request(
            method: "GET", path: "/api/states", token: token,
            maximumBytes: Self.statesResponseByteLimit)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ConnectorError("Home Assistant returned an invalid entity-state response.")
        }
        return array.compactMap(HomeAssistantEntity.init)
    }

    private func fetchEntity(_ entityID: String, token: String) async throws
        -> HomeAssistantEntity {
        let encoded = entityID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? entityID
        let data = try await request(
            method: "GET", path: "/api/states/\(encoded)", token: token,
            maximumBytes: Self.smallResponseByteLimit)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entity = HomeAssistantEntity(object) else {
            throw ConnectorError("Home Assistant returned an invalid state for '\(entityID)'.")
        }
        return entity
    }

    // MARK: Idempotent light writes

    private func setLight(on: Bool, args: ToolArgs, token: String) async throws -> String {
        let entityID = try Self.validEntityID(args.requiredString("entity_id"), domain: "light")
        var body: [String: Any] = ["entity_id": entityID]
        if on, let brightness = args.int("brightness_pct") {
            guard (1...100).contains(brightness) else {
                throw ConnectorError("'brightness_pct' must be between 1 and 100.")
            }
            body["brightness_pct"] = brightness
        }
        if let transition = args.int("transition_seconds") {
            guard (0...30).contains(transition) else {
                throw ConnectorError("'transition_seconds' must be between 0 and 30.")
            }
            body["transition"] = transition
        }
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        _ = try await request(
            method: "POST",
            path: "/api/services/light/\(on ? "turn_on" : "turn_off")",
            token: token, body: encoded,
            maximumBytes: Self.statesResponseByteLimit)
        let setting = on ? "on" : "off"
        let detail = on ? args.int("brightness_pct").map { " at \($0)%" } ?? "" : ""
        return "Turned \(entityID) \(setting)\(detail)."
    }

    // MARK: Transport

    private func configuredToken() throws -> String? {
        guard let token = try tokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    private static func probe(baseURL: String, token: String, session: URLSession) async throws {
        let data = try await request(
            baseURL: baseURL, method: "GET", path: "/api/", token: token,
            maximumBytes: 64 * 1_024, session: session)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String,
              message.localizedCaseInsensitiveContains("API") else {
            throw ConnectorError(
                "The server responded, but it does not look like the Home Assistant REST API.")
        }
    }

    private func request(
        method: String,
        path: String,
        token: String,
        body: Data? = nil,
        maximumBytes: Int
    ) async throws -> Data {
        try await Self.request(
            baseURL: baseURL, method: method, path: path, token: token,
            body: body, maximumBytes: maximumBytes, session: session)
    }

    private static func request(
        baseURL: String,
        method: String,
        path: String,
        token: String,
        body: Data? = nil,
        maximumBytes: Int,
        session: URLSession
    ) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw ConnectorError("Home Assistant URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedHTTP.data(
                for: request, using: session, maximumBytes: maximumBytes,
                delegate: NoRedirectsDelegate())
        } catch {
            throw ConnectorDiagnostics.networkFailure(
                operation: "Home Assistant request", error: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError("Home Assistant returned an invalid network response.")
        }
        if http.statusCode == 401 {
            throw HomeAssistantRequestError.authenticationRejected
        }
        if http.statusCode == 403 {
            throw HomeAssistantRequestError.accessForbidden
        }
        guard (200..<300).contains(http.statusCode) else {
            let safe = ConnectorDiagnostics.redacted(
                String(decoding: data.prefix(500), as: UTF8.self), secrets: [token])
            throw ConnectorError(
                "Home Assistant request failed with HTTP \(http.statusCode)"
                    + (safe.isEmpty ? "." : ": \(safe)"))
        }
        return data
    }

    // MARK: Validation and matching

    private static func validEntityID(_ raw: String, domain: String? = nil) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = "^[a-z0-9_]+\\.[a-z0-9_]+$"
        guard value.range(of: pattern, options: .regularExpression)
                == value.startIndex..<value.endIndex else {
            throw ConnectorError("'entity_id' must be an exact Home Assistant id such as light.desk.")
        }
        if let domain, !value.hasPrefix(domain + ".") {
            throw ConnectorError("This tool accepts only \(domain).* entities.")
        }
        return value
    }

    private static func validOptionalDomain(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.range(of: "^[a-z0-9_]+$", options: .regularExpression)
                == value.startIndex..<value.endIndex else {
            throw ConnectorError("'domain' must look like light, sensor or climate.")
        }
        return value
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func searchScore(_ entity: HomeAssistantEntity, query: String) -> Int {
        guard !query.isEmpty else { return 3 }
        let id = normalized(entity.entityID)
        let name = normalized(entity.friendlyName ?? "")
        if id == query || name == query { return 0 }
        if id.hasPrefix(query) || name.hasPrefix(query) { return 1 }
        return 2
    }
}

public enum HomeAssistantEndpoint {
    /// Normalizes the origin and refuses bearer-token transport over cleartext
    /// unless the host is demonstrably local/private.
    public static func normalizedBaseURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ConnectorError(
                "Use a Home Assistant origin such as http://homeassistant.local:8123, without credentials or a path.")
        }
        if scheme == "http", !isLocalHost(host) {
            throw ConnectorError(
                "A non-local Home Assistant URL must use HTTPS so its token is not sent in cleartext.")
        }
        components.scheme = scheme
        components.path = ""
        guard let normalized = components.url?.absoluteString else {
            throw ConnectorError("Home Assistant URL is invalid.")
        }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    static func isLocalHost(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "localhost" || value == "::1" || value.hasSuffix(".local") {
            return true
        }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            return parts[0] == 10
                || (parts[0] == 172 && (16...31).contains(parts[1]))
                || (parts[0] == 192 && parts[1] == 168)
                || parts[0] == 127
                || (parts[0] == 169 && parts[1] == 254)
        }
        guard value.contains(":") else { return false }
        return value.hasPrefix("fc") || value.hasPrefix("fd") || value.hasPrefix("fe80:")
    }
}

private enum HomeAssistantRequestError: Error, LocalizedError {
    case authenticationRejected
    case accessForbidden

    var errorDescription: String? {
        switch self {
        case .authenticationRejected:
            "Home Assistant rejected the access token."
        case .accessForbidden:
            "Home Assistant refused access. Check whether the user is inactive or local-only, the reverse proxy blocks API access, or this client is IP-banned."
        }
    }
}

private struct HomeAssistantEntity {
    var entityID: String
    var state: String
    var attributes: [String: Any]
    var lastChanged: String?

    init?(_ object: [String: Any]) {
        guard let entityID = object["entity_id"] as? String,
              let state = object["state"] as? String else { return nil }
        self.entityID = entityID
        self.state = state
        self.attributes = object["attributes"] as? [String: Any] ?? [:]
        self.lastChanged = object["last_changed"] as? String
    }

    var domain: String { entityID.split(separator: ".", maxSplits: 1).first.map(String.init) ?? "unknown" }
    var friendlyName: String? { attributes["friendly_name"] as? String }

    func rendered(redacting token: String) -> String {
        let allowedAttributes = [
            "device_class", "unit_of_measurement", "brightness", "color_temp_kelvin",
            "temperature", "current_temperature", "humidity", "battery_level",
            "volume_level", "media_title"
        ]
        var pairs: [(String, JSONText.Value?)] = [
            ("entity_id", .string(entityID)),
            ("name", friendlyName.map(JSONText.Value.string)),
            ("state", .string(state))
        ]
        for key in allowedAttributes {
            pairs.append((key, Self.jsonValue(attributes[key])))
        }
        pairs.append(("last_changed", lastChanged.map(JSONText.Value.string)))
        return ConnectorDiagnostics.redacted(JSONText.object(pairs), secrets: [token])
    }

    private static func jsonValue(_ value: Any?) -> JSONText.Value? {
        switch value {
        case let string as String: .string(string)
        case let bool as Bool: .bool(bool)
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .bool(number.boolValue) : .double(number.doubleValue)
        default: nil
        }
    }
}
