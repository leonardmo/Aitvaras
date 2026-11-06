import Foundation

/// M4 candidate only. The host gate must verify tools, locality and memory
/// before this replaces the existing Local adapter by default.
public struct CodexOSSConfiguration: Sendable {
    public static let provider = "ollama"
    public static let baseURL = URL(string: "http://127.0.0.1:11434")!
    public static let profile = "codex-oss-ollama"
    public let capabilities: Set<AgentCapability> = [.thinking, .tools, .approvals, .plans, .questions]
    private let catalog: @Sendable () async throws -> [AgentModel]

    public init() { catalog = { try await Self.installedModels() } }
    /// Test seam: metadata only; neither discovery nor status loads a model.
    init(catalog: @escaping @Sendable () async throws -> [AgentModel]) { self.catalog = catalog }

    // app-server has config overrides, rather than the interactive CLI's --oss
    // and --local-provider flags. Keep the endpoint independent of OLLAMA_HOST.
    public var arguments: [String] {
        ["app-server", "-c", "model_provider=\"ollama\"", "-c", "local_provider=\"ollama\"",
         "-c", "model_providers.ollama.base_url=\"\(Self.baseURL.absoluteString)/v1\"",
         "-c", "model_providers.ollama.requires_openai_auth=false"]
    }

    public func models() async throws -> [AgentModel] {
        try await catalog().filter { Self.isLocalModel($0.id) }
    }

    static func isLocalModel(_ name: String) -> Bool {
        !name.isEmpty && name != "default" && name != "local"
            && !name.lowercased().contains("cloud")
            && name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/").contains($0) }
    }

    static func installedModels(session: URLSession? = nil) async throws -> [AgentModel] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.connectionProxyDictionary = [:]
        let ownsSession = session == nil
        let session = session ?? URLSession(configuration: configuration, delegate: NoOllamaRedirect(), delegateQueue: nil)
        defer { if ownsSession { session.invalidateAndCancel() } }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url == request.url,
              let value = JSONValue.parse(String(decoding: data, as: UTF8.self)),
              let models = value["models"]?.arrayValue else { throw AgentFailure.offline }
        var seen = Set<String>()
        return try models.compactMap { model in
            guard let name = model["name"]?.stringValue else { throw AgentFailure.offline }
            guard isLocalModel(name),
                  ["remote_host", "remote_model"].allSatisfy({ model[$0] == nil || model[$0] == .null || model[$0]?.stringValue == "" }),
                  seen.insert(name).inserted else { return nil }
            return AgentModel(id: name, name: name)
        }
    }
}

private final class NoOllamaRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum LocalChatBackendFactory {
    /// Single opt-in switch for the host gate. Unknown values fail closed;
    /// an unavailable candidate never selects another backend.
    public static func make(selection: String? = nil, executable: URL? = nil,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            reply: @escaping LocalBackend.Reply) throws -> any AgentBackend {
        switch selection {
        case nil, "agent-loop": return LocalBackend(reply: reply)
        case "codex-oss": return CodexBackend(executable: executable, environment: environment, oss: .init())
        default: throw AgentFailure.invalidRequest
        }
    }
}
