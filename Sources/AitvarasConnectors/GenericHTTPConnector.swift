import Foundation
import AitvarasCore
import AitvarasStore

/// Interprets a `ConnectorManifest` (D17): arbitrary HTTP APIs become typed
/// tools and polling triggers without any Swift code. The bundled Proxmox /
/// TrueNAS / Home Assistant connectors (D10) run on this same engine, which
/// keeps it honest.
public actor GenericHTTPConnector: Connector {
    public let manifest: ConnectorManifest

    public nonisolated var id: String { manifest.id }
    public nonisolated var displayName: String { manifest.displayName }
    public nonisolated var tools: [ToolDefinition] {
        manifest.tools.map {
            ToolDefinition(name: $0.name, description: $0.description,
                           parametersJSON: $0.parametersJSON, risk: $0.risk)
        }
    }

    private let keychain: KeychainStore
    private let stores: Stores
    private let session: URLSession

    private let eventStream: AsyncStream<ConnectorEvent>
    private let eventContinuation: AsyncStream<ConnectorEvent>.Continuation
    private var triggerTasks: [Task<Void, Never>] = []

    /// Maximum characters of response body returned to the model.
    static let responseLimit = 6000

    public init(manifest: ConnectorManifest, keychain: KeychainStore, stores: Stores,
                session: URLSession = .shared) {
        self.manifest = manifest
        self.keychain = keychain
        self.stores = stores
        self.session = session
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: ConnectorEvent.self)
    }

    deinit {
        for task in triggerTasks { task.cancel() }
        eventContinuation.finish()
    }

    public func health() async -> ConnectorHealth {
        guard URL(string: manifest.baseURL) != nil else {
            return .error(message: "Invalid base URL: \(manifest.baseURL)")
        }
        if manifest.auth.type != .none {
            guard let key = manifest.auth.keychainKey else {
                return .error(message: "Manifest auth requires 'keychainKey'.")
            }
            guard let secret = try? keychain.get(key), !secret.isEmpty else {
                return .needsAuthentication(message: "Secret '\(key)' missing — paste it in Settings → Connectors → \(manifest.displayName).")
            }
        }
        return .ready
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        guard let tool = manifest.tools.first(where: { $0.name == toolName }) else {
            throw ConnectorError("\(manifest.displayName) has no tool named '\(toolName)'.")
        }
        let args = try ToolArgs(json: argumentsJSON)
        let request = try ManifestEngine.buildRequest(
            baseURL: manifest.baseURL,
            auth: manifest.auth,
            method: tool.method,
            path: tool.path,
            args: args.stringified,
            bodyTemplate: tool.bodyTemplate,
            secret: try secret())

        let (data, response) = try await session.data(for: request)
        let bodyText = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes of non-UTF-8 data>"
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ConnectorError("\(manifest.displayName) \(tool.name): HTTP \(http.statusCode) — \(String(bodyText.prefix(500)))")
        }
        return truncated(bodyText, limit: Self.responseLimit)
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        eventStream
    }

    /// Start the manifest's polling triggers. Called by the app once the
    /// connector is registered — never self-starting.
    public func startTriggers() {
        guard triggerTasks.isEmpty, !manifest.triggers.isEmpty else { return }
        for trigger in manifest.triggers {
            let interval = max(trigger.intervalSeconds, 5)
            triggerTasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    await self?.pollTrigger(trigger)
                    try? await Task.sleep(for: .seconds(interval))
                }
            })
        }
    }

    public func stopTriggers() {
        for task in triggerTasks { task.cancel() }
        triggerTasks = []
    }

    // MARK: - Trigger polling

    private func pollTrigger(_ trigger: ConnectorManifest.Trigger) async {
        do {
            let request = try ManifestEngine.buildRequest(
                baseURL: manifest.baseURL,
                auth: manifest.auth,
                method: trigger.method,
                path: trigger.path,
                args: [:],
                bodyTemplate: nil,
                secret: try secret())
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
            guard
                let json = try? JSONSerialization.jsonObject(with: data),
                let value = ManifestEngine.value(at: trigger.watchPath, in: json)
            else { return }

            let kvKey = "trigger.\(manifest.id).\(trigger.name)"
            let previous = try? stores.value(forKey: kvKey)
            try? stores.setValue(value, forKey: kvKey)

            // First observation only establishes the baseline; events fire on change.
            guard let previous = previous ?? nil, previous != value else { return }

            let title = ManifestEngine.substitute(
                trigger.titleTemplate,
                args: ["name": trigger.name, "value": value, "previous": previous]).text
            eventContinuation.yield(ConnectorEvent(
                connectorID: manifest.id,
                sourceID: "\(manifest.id):\(trigger.name):\(Date.now.timeIntervalSince1970)",
                title: title,
                body: "\(trigger.watchPath) changed from '\(previous)' to '\(value)'.",
                occurredAt: .now))
        } catch {
            // Trigger errors are silent by design; health() reports auth problems.
        }
    }

    // MARK: - Helpers

    private func secret() throws -> String? {
        guard manifest.auth.type != .none else { return nil }
        guard let key = manifest.auth.keychainKey else {
            throw ConnectorError("Manifest auth for \(manifest.id) requires 'keychainKey'.")
        }
        return try keychain.get(key)
    }
}
