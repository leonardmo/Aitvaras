import Foundation
import AitvarasCore
import AitvarasStore

/// Registry of all active connectors. Routes tool calls, merges event
/// streams, and — critically — is the single place the autonomy policy
/// (D13) is enforced.
public actor ConnectorHub {
    public private(set) var connectors: [String: any Connector] = [:]
    private let stores: Stores
    private var policy: AutonomyPolicy

    public init(stores: Stores, policy: AutonomyPolicy = .init()) {
        self.stores = stores
        self.policy = policy
    }

    public func register(_ connector: any Connector) async {
        let id = await connector.id
        connectors[id] = connector
    }

    /// Remove a connector (user deleted the connection in settings).
    public func unregister(id: String) {
        connectors[id] = nil
    }

    public func updatePolicy(_ policy: AutonomyPolicy) {
        self.policy = policy
    }

    /// All tools across connectors, namespaced "connectorID.toolName" so
    /// the model can't collide names across connectors.
    public func allTools() async -> [ToolDefinition] {
        var result: [ToolDefinition] = []
        for (id, connector) in connectors {
            for tool in await connector.tools {
                var namespaced = tool
                namespaced.name = "\(id).\(tool.name)"
                result.append(namespaced)
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    public enum ExecutionResult: Sendable {
        case output(String)
        /// The action needs user approval; a Suggestion card was stored.
        case awaitingConfirmation(Suggestion)
    }

    /// Execute a namespaced tool call under policy, recording activity
    /// with provenance.
    public func execute(call: ToolCall, causedBy: UUID?, sourceID: String?) async throws -> ExecutionResult {
        let parts = call.toolName.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let connector = connectors[String(parts[0])] else {
            throw NSError(domain: "ConnectorHub", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Unknown tool: \(call.toolName)"
            ])
        }
        let connectorID = String(parts[0])
        let bareName = String(parts[1])

        guard let tool = await connector.tools.first(where: { $0.name == bareName }) else {
            throw NSError(domain: "ConnectorHub", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Connector \(connectorID) has no tool \(bareName)"
            ])
        }

        switch policy.verdict(for: tool, connectorID: connectorID) {
        case .requireConfirmation:
            let suggestion = Suggestion(
                title: "Aitvaras wants to run \(bareName)",
                detail: tool.description,
                connectorID: connectorID,
                toolName: bareName,
                argumentsJSON: call.argumentsJSON,
                causedBy: causedBy
            )
            try stores.saveSuggestion(suggestion)
            try stores.record(ActivityEvent(
                kind: .suggestionOffered,
                connectorID: connectorID,
                summary: "Awaiting confirmation: \(bareName)",
                detailJSON: call.argumentsJSON,
                causedBy: causedBy,
                sourceID: sourceID))
            return .awaitingConfirmation(suggestion)

        case .allow:
            do {
                let output = try await connector.execute(toolName: bareName, argumentsJSON: call.argumentsJSON)
                try stores.record(ActivityEvent(
                    kind: .toolExecuted,
                    connectorID: connectorID,
                    summary: "\(bareName): ok",
                    detailJSON: call.argumentsJSON,
                    causedBy: causedBy,
                    sourceID: sourceID))
                return .output(output)
            } catch {
                try stores.record(ActivityEvent(
                    kind: .toolExecuted,
                    connectorID: connectorID,
                    summary: "\(bareName) failed: \(error.localizedDescription)",
                    detailJSON: call.argumentsJSON,
                    causedBy: causedBy,
                    sourceID: sourceID))
                throw error
            }
        }
    }

    /// Execute a previously-confirmed suggestion (user tapped accept).
    public func executeSuggestion(_ suggestion: Suggestion) async -> String {
        guard let connector = connectors[suggestion.connectorID] else {
            try? stores.updateSuggestionStatus(suggestion.id, to: "failed")
            return "Connector \(suggestion.connectorID) is not available."
        }
        do {
            try? stores.updateSuggestionStatus(suggestion.id, to: "accepted")
            try stores.record(ActivityEvent(
                kind: .suggestionAccepted,
                connectorID: suggestion.connectorID,
                summary: "Accepted: \(suggestion.title)",
                causedBy: suggestion.causedBy))
            let output = try await connector.execute(
                toolName: suggestion.toolName, argumentsJSON: suggestion.argumentsJSON)
            try? stores.updateSuggestionStatus(suggestion.id, to: "executed")
            try? stores.record(ActivityEvent(
                kind: .toolExecuted,
                connectorID: suggestion.connectorID,
                summary: "\(suggestion.toolName): ok (confirmed by user)",
                detailJSON: suggestion.argumentsJSON,
                causedBy: suggestion.causedBy))
            return output
        } catch {
            try? stores.updateSuggestionStatus(suggestion.id, to: "failed")
            try? stores.record(ActivityEvent(
                kind: .toolExecuted,
                connectorID: suggestion.connectorID,
                summary: "\(suggestion.toolName) failed: \(error.localizedDescription)",
                causedBy: suggestion.causedBy))
            return "Failed: \(error.localizedDescription)"
        }
    }

    public func rejectSuggestion(_ suggestion: Suggestion) {
        try? stores.updateSuggestionStatus(suggestion.id, to: "rejected")
        try? stores.record(ActivityEvent(
            kind: .suggestionRejected,
            connectorID: suggestion.connectorID,
            summary: "Rejected: \(suggestion.title)",
            causedBy: suggestion.causedBy))
    }

    /// Merged event stream from every connector.
    public func mergedEvents() async -> AsyncStream<ConnectorEvent> {
        let all = Array(connectors.values)
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for connector in all {
                        group.addTask {
                            for await event in await connector.events() {
                                continuation.yield(event)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
