import Foundation
import AitvarasCore

/// Only Aitvaras-owned configuration is loaded. No user/project plugins,
/// credentials, remote providers or inherited endpoint overrides are admitted.
public struct OpencodeConfiguration: Sendable {
    public static let profile = "opencode"
    public static let ollamaURL = URL(string: "http://127.0.0.1:11434")!
    public let root: URL
    public let temporaryDirectory: URL
    public init(root: URL = AitvarasPaths.opencodeDirectory,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.temporaryDirectory = temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
    }
    public var dataDirectories: [URL] {
        ["config", "data", "cache", "state", "home"].map { root.appendingPathComponent($0, isDirectory: true) }
    }
    public func environment(_ inherited: [String: String]) -> [String: String] {
        // ProviderEnvironment removes known CLI overrides; an allowlist additionally
        // keeps opencode/plugin/proxy/credential configuration out of this child.
        let cleaned = ProviderEnvironment.make(inherited: inherited)
        var result = cleaned.filter { ["PATH", "LANG", "LC_ALL", "TERM", "SHELL"].contains($0.key) }
        for (key, directory) in zip(["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "HOME"], dataDirectories) {
            result[key] = directory.path
        }
        result["TMPDIR"] = temporaryDirectory.path
        result["OPENCODE_CONFIG"] = dataDirectories[0].appendingPathComponent("opencode/opencode.json").path
        result["OPENCODE_DISABLE_PROJECT_CONFIG"] = "true"
        result["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = "true"
        result["OPENCODE_DISABLE_DEFAULT_PLUGINS"] = "true"
        result["NO_PROXY"] = "127.0.0.1,localhost,::1"
        return result
    }
    public func config(models: [AgentModel]) -> JSONValue {
        .object([
            "share": .string("disabled"), "autoupdate": .bool(false),
            "enabled_providers": .array([.string("ollama")]),
            "plugin": .array([]), "mcp": .object([:]),
            "provider": .object(["ollama": .object([
                "npm": .string("@ai-sdk/openai-compatible"), "name": .string("Ollama (this Mac)"),
                "options": .object(["baseURL": .string(Self.ollamaURL.absoluteString + "/v1")]),
                "models": .object(Dictionary(uniqueKeysWithValues: models.map {
                    ($0.id, .object(["name": .string($0.name), "tools": .bool(true)]))
                }))])]),
            // Native auto-allow would bypass the app's audit/policy boundary.
            // All actions ask; the coordinator may auto-authorize safe edits.
            "permission": .object(["*": .string("ask"), "bash": .string("ask"),
                "edit": .string("ask"), "webfetch": .string("ask"), "websearch": .string("deny")])
        ])
    }
    public static func permissions(mode: AgentMode) -> JSONValue {
        var rules: [JSONValue] = [.object(["action": .string("*"), "resource": .string("*"), "effect": .string("ask")])]
        // Plan forbids shell as well as edits: shell cannot be made read-only
        // by classifying command text. Other modes always pass the coordinator.
        for action in (mode == .plan ? ["bash", "edit", "webfetch", "websearch"] : ["websearch"]) {
            rules.append(.object(["action": .string(action), "resource": .string("*"), "effect": .string("deny")]))
        }
        return .array(rules)
    }
    public func sandbox(projects: [URL]) throws -> String {
        let roots = try Self.writeRoots(projects + dataDirectories + [temporaryDirectory])
        let paths = roots.map { "(subpath \(Self.quote($0)))" }.joined(separator: " ")
        return """
        (version 1)
        (allow default)
        (deny network*)
        (allow network-bind (local ip "localhost:*"))
        (allow network-inbound (local ip "localhost:*"))
        (allow network-outbound (remote ip "localhost:*"))
        (deny file-write*)
        (allow file-write* \(paths))
        """
    }
    static func writeRoots(_ urls: [URL]) throws -> [String] {
        try Array(Set(urls.map {
            guard $0.isFileURL, $0.path.hasPrefix("/"), !$0.path.contains("\0") else { throw AgentFailure.invalidRequest }
            let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != "/" else { throw AgentFailure.invalidRequest }
            return path
        })).sorted()
    }
    private static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    public static func installedModels(session injected: URLSession? = nil) async throws -> [AgentModel] {
        let session = injected ?? localHTTPSession()
        defer { if injected == nil { session.invalidateAndCancel() } }
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url == request.url,
                  let models = JSONValue.parse(String(decoding: data, as: UTF8.self))?["models"]?.arrayValue else { throw AgentFailure.offline }
            var seen = Set<String>()
            return models.compactMap { model in
                guard let name = model["name"]?.stringValue, isLocalModel(name),
                      ["remote_host", "remote_model"].allSatisfy({ key in model[key] == nil || model[key] == .null || model[key]?.stringValue == "" }),
                      seen.insert(name).inserted else { return nil }
                return AgentModel(id: name, name: name)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw AgentFailure.offline }
    }
    static func isLocalModel(_ name: String) -> Bool {
        !name.isEmpty && name != "default" && name != "local" && !name.lowercased().contains("cloud")
            && name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/").contains($0) }
    }
}

final class OpencodeNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
func localHTTPSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
    return URLSession(configuration: configuration, delegate: OpencodeNoRedirect(), delegateQueue: nil)
}

public enum LocalChatBackendFactory {
    public static func make(executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                            reply: @escaping LocalBackend.Reply) -> any AgentBackend {
        if let executable = ProviderLocator.executable(for: .local, environment: environment,
            overrides: executable.map { [.local: $0] } ?? [:]) {
            return OpencodeBackend(executable: executable, environment: environment)
        }
        return LocalBackend(reply: reply)
    }
}
