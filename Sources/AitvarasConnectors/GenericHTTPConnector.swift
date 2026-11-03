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
    private let reporter: ActivityReporter?

    private let eventStream: AsyncStream<ConnectorEvent>
    private let eventContinuation: AsyncStream<ConnectorEvent>.Continuation
    private var triggerTasks: [Task<Void, Never>] = []
    private var triggerErrors: [String: String] = [:]

    /// Maximum characters of response body returned to the model.
    static let responseLimit = 6000
    /// Maximum raw response held while parsing JSON or rendering tool output.
    static let responseByteLimit = 1024 * 1024
    /// Trigger checkpoints should be scalar/small values, not response trees.
    static let observedValueByteLimit = 4 * 1024

    public init(manifest: ConnectorManifest, keychain: KeychainStore, stores: Stores,
                session: URLSession = ConnectorHTTPSession.make(), reporter: ActivityReporter? = nil) {
        self.manifest = manifest
        self.keychain = keychain
        self.stores = stores
        self.session = session
        self.reporter = reporter
        (self.eventStream, self.eventContinuation) = ConnectorEventStreams.make()
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
            do {
                guard let secret = try keychain.get(key), !secret.isEmpty else {
                    return .needsAuthentication(message: "Secret '\(key)' missing — paste it in Settings → Connectors → \(manifest.displayName).")
                }
            } catch {
                return .error(message: "Connector credentials could not be checked: \(error.localizedDescription)")
            }
        }
        if let failed = triggerErrors.keys.sorted().first,
           let message = triggerErrors[failed] {
            return .error(message: "Polling '\(failed)' failed: \(message)")
        }
        return .ready
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        guard let tool = manifest.tools.first(where: { $0.name == toolName }) else {
            throw ConnectorError("\(manifest.displayName) has no tool named '\(toolName)'.")
        }
        let args = try ToolArgs(json: argumentsJSON)
        let credential = try secret()
        let request = try ManifestEngine.buildRequest(
            baseURL: manifest.baseURL,
            auth: manifest.auth,
            method: tool.method,
            path: tool.path,
            args: args.stringified,
            bodyTemplate: tool.bodyTemplate,
            secret: credential)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedHTTP.data(
                for: request, using: session,
                maximumBytes: Self.responseByteLimit)
        } catch {
            throw ConnectorDiagnostics.networkFailure(
                operation: "\(manifest.displayName) request", error: error)
        }
        let bodyText = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes of non-UTF-8 data>"
        let safeBodyText = ConnectorDiagnostics.redacted(
            bodyText, secrets: credential.map { [$0] } ?? [])
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ConnectorError("\(manifest.displayName) \(tool.name): HTTP \(http.statusCode) — \(String(safeBodyText.prefix(500)))")
        }
        return truncated(safeBodyText, limit: Self.responseLimit)
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        eventStream
    }

    /// Start the manifest's polling triggers. Called by the app once the
    /// connector is registered — never self-starting.
    public func startTriggers() {
        guard triggerTasks.isEmpty, !manifest.triggers.isEmpty, automaticChecksAllowed else { return }
        for trigger in manifest.triggers {
            let interval = max(trigger.intervalSeconds, 5)
            triggerTasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    await self?.pollTrigger(trigger, triggerKind: .automatic)
                    do { try await Task.sleep(for: .seconds(interval)) }
                    catch { return }
                }
            })
        }
    }

    public func stopTriggers() async {
        let previous = triggerTasks
        for task in previous { task.cancel() }
        triggerTasks = []
        for task in previous { await task.value }
        reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
            enabled: false, paused: true, stage: "Automatic connection checks paused"))
    }

    // MARK: - Trigger polling

    func pollTrigger(_ trigger: ConnectorManifest.Trigger, triggerKind: ActivityTrigger = .manual) async {
        guard pollAllowed(triggerKind) else { return }
        let enabled = automaticChecksAllowed
        reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
            enabled: enabled, paused: !enabled,
            stage: "Checking connection", lastAttempt: .now,
            problem: triggerErrors.isEmpty ? nil : "A previous connection check failed; retrying."))
        guard pollAllowed(triggerKind) else { return }
        do {
            let credential = try secret()
            let request = try ManifestEngine.buildRequest(
                baseURL: manifest.baseURL,
                auth: manifest.auth,
                method: trigger.method,
                path: trigger.path,
                args: [:],
                bodyTemplate: nil,
                secret: credential)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await BoundedHTTP.data(
                    for: request, using: session,
                    maximumBytes: Self.responseByteLimit)
            } catch {
                throw ConnectorDiagnostics.networkFailure(
                    operation: "\(manifest.displayName) polling", error: error)
            }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw ConnectorError("HTTP \(http.statusCode)")
            }
            let json = try JSONSerialization.jsonObject(with: data)
            guard let observedValue = ManifestEngine.value(
                at: trigger.watchPath, in: json) else {
                throw ConnectorError("Response has no value at '\(trigger.watchPath)'.")
            }
            let value = try Self.checkedObservedValue(ConnectorDiagnostics.redacted(
                observedValue, secrets: credential.map { [$0] } ?? []))

            guard pollAllowed(triggerKind) else { return }

            let kvKey = "trigger.\(manifest.id).\(trigger.name)"
            // The first observation establishes a durable baseline. Changed
            // values remain uncommitted until central intake stores the root
            // activity event, dedup marker and checkpoint together.
            let previous = try Self.previousValue(
                establishing: value, key: kvKey, stores: stores)
            triggerErrors[trigger.name] = nil
            reportPollResult(succeeded: true)

            // First observation only establishes the baseline; events fire on change.
            guard let previous, previous != value else { return }
            guard pollAllowed(triggerKind) else { return }

            let title = Self.eventPreview(ManifestEngine.substitute(
                trigger.titleTemplate,
                args: ["name": trigger.name, "value": value, "previous": previous]).text,
                limit: 500)
            let transitionID = StableIdentifier.short([
                manifest.id, trigger.name, previous, value
            ])
            eventContinuation.yield(ConnectorEvent(
                connectorID: manifest.id,
                sourceID: "\(manifest.id):\(trigger.name):\(transitionID)",
                title: title,
                body: "\(trigger.watchPath) changed from "
                    + "'\(Self.eventPreview(previous, limit: 500))' to "
                    + "'\(Self.eventPreview(value, limit: 500))'.",
                occurredAt: .now,
                checkpoint: ConnectorCheckpoint(key: kvKey, value: value),
                externalMessageSource: .configuredService(
                    id: manifest.id, displayName: manifest.displayName)))
        } catch {
            if pollAllowed(triggerKind) {
                triggerErrors[trigger.name] = error.localizedDescription
                reportPollResult(succeeded: false)
            }
        }
    }

    private var automaticChecksAllowed: Bool {
        reporter?.failureMessage == nil
            && (try? stores.backgroundWorkPolicy().permits(.connectors, trigger: .automatic)) == true
    }

    private func pollAllowed(_ trigger: ActivityTrigger) -> Bool {
        guard !Task.isCancelled else { return false }
        guard trigger != .manual else { return true }
        let allowed = automaticChecksAllowed
        if !allowed {
            reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
                enabled: false, paused: true, stage: "Automatic connection checks not permitted"))
        }
        return allowed
    }

    private func reportPollResult(succeeded: Bool) {
        let now = Date.now
        let enabled = automaticChecksAllowed
        let interval = manifest.triggers.map { max(5, $0.intervalSeconds) }.min()
        reporter?.serviceCheck(id: id, succeeded: succeeded, at: now)
        reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
            enabled: enabled, paused: !enabled,
            stage: triggerErrors.isEmpty ? "Waiting for next check" : "Connection check failed",
            lastAttempt: now, lastSuccess: succeeded ? now : nil,
            nextOpportunity: enabled ? interval.map { now.addingTimeInterval(TimeInterval($0)) } : nil,
            problem: triggerErrors.isEmpty ? nil : "A connection check failed. Review the configured connection."))
    }

    // MARK: - Helpers

    private func secret() throws -> String? {
        guard manifest.auth.type != .none else { return nil }
        guard let key = manifest.auth.keychainKey else {
            throw ConnectorError("Manifest auth for \(manifest.id) requires 'keychainKey'.")
        }
        return try keychain.get(key)
    }

    static func previousValue(establishing value: String, key: String,
                              stores: Stores) throws -> String? {
        let previous = try stores.value(forKey: key)
        if previous == nil {
            try stores.setValue(value, forKey: key)
        }
        return previous
    }

    static func checkedObservedValue(_ value: String) throws -> String {
        guard value.utf8.count <= observedValueByteLimit else {
            throw ConnectorError(
                "Watched value is larger than \(observedValueByteLimit / 1024) KB. "
                    + "Choose a watchPath that points to a smaller scalar value.")
        }
        return value
    }

    static func eventPreview(_ value: String, limit: Int) -> String {
        let oneLine = value.split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
        return String(oneLine.prefix(limit))
    }
}
