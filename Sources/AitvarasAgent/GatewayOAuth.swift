import Foundation
import CryptoKit
import Security
import AitvarasAgents

public enum GatewayOAuthError: Error, Sendable, Equatable {
    case invalidMetadata, invalidResponse, invalidCallback, rejected, busy, timedOut
}

struct GatewayHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    var json: JSONValue? { JSONValue.parse(String(decoding: body, as: UTF8.self)) }

    subscript(_ header: String) -> String? { headers[header.lowercased()] }
}

typealias GatewayHTTP = @Sendable (URLRequest, JSONValue?) async throws -> GatewayHTTPResponse

enum GatewayHTTPClient {
    static func make() -> GatewayHTTP {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        return { request, id in
            do {
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let response = response as? HTTPURLResponse else { throw GatewayOAuthError.invalidResponse }
                let headers = response.allHeaderFields.reduce(into: [String: String]()) { fields, pair in
                    if let name = pair.key as? String, let value = pair.value as? String { fields[name.lowercased()] = value }
                }
                if [401, 403].contains(response.statusCode) {
                    return .init(status: response.statusCode, headers: headers, body: Data())
                }
                var body = Data(), event = Data()
                let sse = headers["content-type"]?.lowercased().hasPrefix("text/event-stream") == true
                // A notification can return a streaming acknowledgement. No reply ID is expected.
                if sse, id == nil { return .init(status: response.statusCode, headers: headers, body: body) }
                for try await byte in bytes {
                    guard body.count < 256 * 1024 else { throw GatewayOAuthError.invalidResponse }
                    body.append(byte)
                    if sse {
                        event.append(byte)
                        if byte == 10, event.suffix(2) == Data([10, 10]) || event.suffix(4) == Data([13, 10, 13, 10]) {
                            let payload = String(decoding: event, as: UTF8.self).split(whereSeparator: \.isNewline)
                                .filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5) }.joined(separator: "\n")
                            if let value = JSONValue.parse(payload), value["id"] == id {
                                return .init(status: response.statusCode, headers: headers, body: Data(value.jsonString.utf8))
                            }
                            event.removeAll(keepingCapacity: true)
                        }
                    }
                }
                return .init(status: response.statusCode, headers: headers, body: body)
            } catch {
                try Task.checkCancellation()
                throw GatewayOAuthError.invalidResponse
            }
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

struct GatewayOAuth: Sendable {
    struct Discovery: Codable, Sendable {
        let issuer: URL
        let authorize: URL
        let token: URL
        let registration: URL
        let resource: URL?
        let scope: String?
        let clientSecretPost: Bool
    }

    struct Client: Codable, Sendable {
        let id: String
        let secret: String?
    }

    struct Credentials: Codable, Sendable {
        let discovery: Discovery
        let client: Client
        let access: String
        let refresh: String?
        let expires: Date
    }

    let send: GatewayHTTP
    let endpoint: URL

    static func validated(_ url: URL?) throws -> URL {
        guard let url, url.absoluteString.utf8.count <= 4096, url.fragment == nil,
              let host = url.host?.lowercased(), host.contains("."), !host.hasSuffix("."),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              host.utf8.contains(where: { (97...122).contains($0) }),
              !host.contains(":") else { throw GatewayOAuthError.invalidMetadata }
        do { try ProviderSignIn.validate(url) }
        catch { throw GatewayOAuthError.invalidMetadata }
        return url
    }

    private func wellKnown(_ url: URL, _ name: String, suffix: Bool = false) throws -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = components.percentEncodedPath == "/" ? "" : components.percentEncodedPath
        components.percentEncodedPath = suffix ? path + "/.well-known/" + name : "/.well-known/" + name + path
        components.query = nil
        return try Self.validated(components.url)
    }

    func discover() async throws -> Discovery {
        let endpoint = try Self.validated(endpoint)
        let probe = try await send(Self.rpc(endpoint, method: "initialize", id: .number(1),
            params: GatewayRemoteSession.initialize, authorization: nil), .number(1))
        let challenge = probe["www-authenticate"] ?? ""
        let advertised = Self.parameter("resource_metadata", in: challenge)
        let prmURL = try advertised.map { try Self.validated(URL(string: $0)) }
            ?? wellKnown(endpoint, "oauth-protected-resource")
        let prm = try await send(URLRequest(url: prmURL), nil)
        let resource: URL?
        let issuer: URL
        let scope: String?
        if prm.status == 200 {
            guard let metadata = prm.json, let resourceURL = metadata["resource"]?.stringValue,
                  let advertisedResource = try? Self.validated(URL(string: resourceURL)),
                  Self.sameResource(advertisedResource, endpoint),
                  let first = metadata["authorization_servers"]?.arrayValue?.first?.stringValue else {
                throw GatewayOAuthError.invalidMetadata
            }
            resource = advertisedResource
            issuer = try Self.validated(URL(string: first))
            scope = Self.parameter("scope", in: challenge) ?? Self.scopes(metadata)
        } else {
            guard advertised == nil, [404, 405].contains(prm.status) else { throw GatewayOAuthError.invalidMetadata }
            var origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            origin.path = ""; origin.query = nil
            issuer = try Self.validated(origin.url)
            resource = nil
            scope = Self.parameter("scope", in: challenge)
        }
        guard issuer.query == nil else { throw GatewayOAuthError.invalidMetadata }

        let candidates = try [wellKnown(issuer, "oauth-authorization-server"),
                              wellKnown(issuer, "openid-configuration"),
                              wellKnown(issuer, "openid-configuration", suffix: true)]
        for candidate in candidates {
            let response = try await send(URLRequest(url: candidate), nil)
            if [404, 405].contains(response.status) { continue }
            guard response.status == 200, let meta = response.json,
                  let identity = meta["issuer"]?.stringValue, let identityURL = URL(string: identity),
                  Self.sameResource(identityURL, issuer),
                  meta["code_challenge_methods_supported"]?.arrayValue?.contains(.string("S256")) == true else {
                throw GatewayOAuthError.invalidMetadata
            }
            let methods = meta["token_endpoint_auth_methods_supported"]?.arrayValue
            let clientSecretPost = methods?.contains(.string("none")) == false
            if clientSecretPost, methods?.contains(.string("client_secret_post")) != true { throw GatewayOAuthError.invalidMetadata }
            return try .init(issuer: issuer,
                authorize: Self.validated(meta["authorization_endpoint"]?.stringValue.flatMap(URL.init(string:))),
                token: Self.validated(meta["token_endpoint"]?.stringValue.flatMap(URL.init(string:))),
                registration: Self.validated(meta["registration_endpoint"]?.stringValue.flatMap(URL.init(string:))),
                resource: resource, scope: scope, clientSecretPost: clientSecretPost)
        }
        throw GatewayOAuthError.invalidMetadata
    }

    func register(_ discovery: Discovery, redirect: URL) async throws -> Client {
        var request = URLRequest(url: discovery.registration)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(JSONValue.object(["client_name": .string("Aitvaras"),
            "redirect_uris": .array([.string(redirect.absoluteString)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string(discovery.clientSecretPost ? "client_secret_post" : "none")]).jsonString.utf8)
        let response = try await send(request, nil)
        guard [200, 201].contains(response.status), let json = response.json,
              let id = Self.credential(json["client_id"], maximum: 1024) else { throw GatewayOAuthError.rejected }
        let secret = Self.credential(json["client_secret"])
        guard !discovery.clientSecretPost || secret != nil else { throw GatewayOAuthError.rejected }
        return .init(id: id, secret: discovery.clientSecretPost ? secret : nil)
    }

    func browserURL(_ discovery: Discovery, client: Client, redirect: URL, state: String, verifier: String) throws -> URL {
        var url = URLComponents(url: discovery.authorize, resolvingAgainstBaseURL: false)!
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var fields = ["response_type": "code", "client_id": client.id, "redirect_uri": redirect.absoluteString,
                      "state": state, "code_challenge": challenge, "code_challenge_method": "S256"]
        fields["resource"] = discovery.resource?.absoluteString
        fields["scope"] = discovery.scope
        guard (url.queryItems ?? []).allSatisfy({ fields[$0.name] == nil }) else { throw GatewayOAuthError.invalidMetadata }
        url.queryItems = (url.queryItems ?? []) + fields.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        return try Self.validated(url.url)
    }

    static func code(_ callback: URL, redirect: URL, state: String, issuer: URL) throws -> String {
        guard let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              callback.user == nil, callback.password == nil, callback.fragment == nil,
              callback.scheme == redirect.scheme, callback.host == redirect.host, callback.port == redirect.port,
              callback.path == redirect.path else { throw GatewayOAuthError.invalidCallback }
        let values = Dictionary(grouping: actual.queryItems ?? [], by: \.name)
        guard values.values.allSatisfy({ $0.count == 1 }), values["state"]?.first?.value == state,
              values["error"] == nil, let code = values["code"]?.first?.value,
              credential(.string(code)) != nil else { throw GatewayOAuthError.invalidCallback }
        if let reported = values["iss"]?.first?.value, reported != issuer.absoluteString {
            throw GatewayOAuthError.invalidCallback
        }
        return code
    }

    func exchange(_ discovery: Discovery, client: Client, fields: [String: String], previousRefresh: String? = nil) async throws -> Credentials {
        var form = fields
        form["client_id"] = client.id
        form["client_secret"] = client.secret
        form["resource"] = discovery.resource?.absoluteString
        var request = URLRequest(url: discovery.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(form.sorted(by: { $0.key < $1.key }).map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" +
            ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
        let response = try await send(request, nil)
        guard response.status == 200 else {
            if response.json?["error"]?.stringValue == "invalid_grant" || [401, 403].contains(response.status) {
                throw GatewayOAuthError.rejected
            }
            throw GatewayOAuthError.invalidResponse
        }
        guard let json = response.json, json["token_type"]?.stringValue?.lowercased() == "bearer",
              let access = Self.credential(json["access_token"]) else { throw GatewayOAuthError.invalidResponse }
        let refresh = Self.credential(json["refresh_token"])
        let seconds = json["expires_in"]?.doubleValue
            ?? json["expires_in"]?.stringValue.flatMap(Double.init) ?? (json["expires_in"] == nil ? 3600 : 0)
        guard seconds.isFinite, seconds > 0, json["refresh_token"] == nil || refresh != nil else {
            throw GatewayOAuthError.invalidResponse
        }
        return .init(discovery: discovery, client: client, access: access, refresh: refresh ?? previousRefresh,
                     expires: Date().addingTimeInterval(min(seconds, 86400 * 365)))
    }

    static func rpc(_ endpoint: URL, method: String, id: JSONValue?, params: JSONValue?,
                    authorization: String?, headerName: String? = nil,
                    sessionID: String? = nil, version: String? = nil) -> URLRequest {
        var body: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        body["id"] = id; body["params"] = params
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let authorization {
            if let headerName { request.setValue(authorization, forHTTPHeaderField: headerName) }
            else { request.setValue("Bearer " + authorization, forHTTPHeaderField: "Authorization") }
        }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = Data(JSONValue.object(body).jsonString.utf8)
        return request
    }

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw GatewayOAuthError.invalidResponse }
        return base64url(Data(bytes))
    }

    static func credential(_ value: JSONValue?, maximum: Int = 16_384) -> String? {
        guard let text = value?.stringValue, !text.isEmpty, text.utf8.count <= maximum,
              text.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return text
    }

    private static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func sameResource(_ first: URL, _ second: URL) -> Bool {
        first.scheme == second.scheme && first.host == second.host && (first.port ?? 443) == (second.port ?? 443)
            && (first.path.isEmpty ? "/" : first.path) == (second.path.isEmpty ? "/" : second.path) && first.query == second.query
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        guard let range = header.range(of: "\(name)=\"", options: .caseInsensitive) else { return nil }
        return header[range.upperBound...].split(separator: "\"", maxSplits: 1).first.map(String.init)
    }

    private static func scopes(_ metadata: JSONValue) -> String? {
        let scopes = metadata["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return scopes.isEmpty ? nil : scopes.joined(separator: " ")
    }
}
