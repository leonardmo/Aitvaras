import Foundation
import AitvarasCore
import AitvarasStore

/// Registry of all active connectors. Routes tool calls, merges event
/// streams, and — critically — is the single place the autonomy policy
/// (D13) is enforced.
public actor ConnectorHub {
    /// Model-generated JSON is persisted in confirmations/audit entries, so
    /// reject pathological calls before they can reach either storage or a
    /// connector. Normal tool calls are typically well under one kilobyte.
    static let maximumToolArgumentsBytes = 64 * 1_024
    /// A connector may read a large local/remote result, but only a bounded
    /// excerpt belongs in the next model prompt or a caller's live UI state.
    static let maximumToolOutputCharacters = 16_000
    /// External messages may only propose new local planning items. They can
    /// never read mail, memory, files, web pages, or existing user data.
    public static let externalMessageToolNames: Set<String> = [
        "calendar.create_event",
        "reminders.create_reminder"
    ]

    public struct HealthSnapshot: Sendable, Equatable {
        public var id: String
        public var displayName: String
        public var health: ConnectorHealth

        public init(id: String, displayName: String, health: ConnectorHealth) {
            self.id = id
            self.displayName = displayName
            self.health = health
        }
    }

    public private(set) var connectors: [String: any Connector] = [:]
    private let stores: Stores
    private let reporter: ActivityReporter?
    private var policy: AutonomyPolicy
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var eventContinuations: [UUID: AsyncStream<ConnectorEvent>.Continuation] = [:]

    public init(stores: Stores, policy: AutonomyPolicy = .init(), reporter: ActivityReporter? = nil) {
        self.stores = stores
        self.policy = policy
        self.reporter = reporter
    }

    public func register(_ connector: any Connector) async {
        let id = await connector.id
        eventTasks[id]?.cancel()
        connectors[id] = connector
        eventTasks[id] = Task { [weak self] in
            for await event in await connector.events() {
                guard !Task.isCancelled else { break }
                await self?.broadcast(event)
            }
        }
    }

    /// Remove a connector (user deleted the connection in settings).
    public func unregister(id: String) {
        eventTasks.removeValue(forKey: id)?.cancel()
        connectors[id] = nil
    }

    public func updatePolicy(_ policy: AutonomyPolicy) {
        self.policy = policy
    }

    /// Live connector state for the Connections screen. Polling connectors
    /// include their most recent background failure in `health()` so a stale
    /// integration is visible instead of looking quietly healthy.
    public func healthSnapshots() async -> [HealthSnapshot] {
        var snapshots: [HealthSnapshot] = []
        for (id, connector) in connectors {
            snapshots.append(HealthSnapshot(
                id: id,
                displayName: await connector.displayName,
                health: await connector.health()))
        }
        return snapshots.sorted { $0.displayName < $1.displayName }
    }

    /// All tools across connectors, namespaced "connectorID.toolName" so
    /// the model can't collide names across connectors.
    public func allTools(externalMessageOnly: Bool = false) async -> [ToolDefinition] {
        var result: [ToolDefinition] = []
        for (id, connector) in connectors {
            for tool in await connector.tools {
                var namespaced = tool
                namespaced.name = "\(id).\(tool.name)"
                if externalMessageOnly,
                   !Self.externalMessageToolNames.contains(namespaced.name) {
                    continue
                }
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

    /// Snapshot the exact low-risk path chosen by the model. The learner keeps
    /// only canonical arguments and tool metadata—never connector output or
    /// model reasoning.
    public func commandRoutineStep(for call: ToolCall) async -> CommandRoutineStep? {
        let parts = call.toolName.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let connector = connectors[String(parts[0])],
              let canonical = CommandRoutineStep.canonicalJSON(call.argumentsJSON),
              let tool = await connector.tools.first(where: { $0.name == String(parts[1]) })
        else { return nil }
        return CommandRoutineStep(
            connectorID: String(parts[0]),
            toolName: String(parts[1]),
            argumentsJSON: canonical,
            risk: tool.risk)
    }

    /// Execute one human-visible, previously compiled workflow step. This is
    /// deliberately stricter than ordinary agent autonomy: confirmable tools
    /// can never enter the deterministic path, even if globally whitelisted.
    public func executeCommandRoutineStep(
        _ step: CommandRoutineStep, causedBy: UUID
    ) async throws -> String {
        try Task.checkCancellation()
        guard step.argumentsJSON.utf8.count <= Self.maximumToolArgumentsBytes else {
            throw CommandRoutineError.invalidWorkflow
        }
        guard let connector = connectors[step.connectorID],
              let current = await connector.tools.first(where: { $0.name == step.toolName })
        else { throw CommandRoutineError.staleWorkflow(step.namespacedToolName) }
        guard current.risk == step.risk else {
            throw CommandRoutineError.staleWorkflow(step.namespacedToolName)
        }
        guard current.risk == .read || current.risk == .reversibleWrite else {
            throw CommandRoutineError.unsafeStep(step.namespacedToolName)
        }

        do {
            let output = try await executeTracked(connector, connectorID: step.connectorID,
                toolName: step.toolName, argumentsJSON: step.argumentsJSON, risk: current.risk)
            // Tool completion and audit persistence are separate boundaries:
            // never report a completed side effect as a retryable failure.
            let auditSaved = (try? stores.record(ActivityEvent(
                kind: .toolExecuted,
                connectorID: step.connectorID,
                summary: "\(step.toolName): ok (deterministic routine)",
                detailJSON: step.argumentsJSON,
                causedBy: causedBy))) != nil
            return Self.boundedOutput(output + (auditSaved ? "" : "\nWarning: completed, but the audit record could not be saved. Do not retry."))
        } catch {
            let executionError = error
            _ = try? stores.record(ActivityEvent(
                kind: .toolExecuted,
                connectorID: step.connectorID,
                summary: "\(step.toolName) failed in routine: \(executionError.localizedDescription)",
                detailJSON: step.argumentsJSON,
                causedBy: causedBy))
            throw executionError
        }
    }

    /// Execute a namespaced tool call under policy, recording activity
    /// with provenance.
    public func execute(call: ToolCall, causedBy: UUID?, sourceID: String?) async throws -> ExecutionResult {
        try Task.checkCancellation()
        guard call.argumentsJSON.utf8.count <= Self.maximumToolArgumentsBytes else {
            throw Self.error(
                "The model produced oversized tool arguments. Nothing was executed; try a narrower request.")
        }
        if sourceID != nil,
           !Self.externalMessageToolNames.contains(call.toolName) {
            throw Self.error(
                "External message content is quarantined and cannot use \(call.toolName). Nothing was executed.")
        }
        if sourceID != nil,
           MessageTrustPolicy.containsURLLikeText(call.argumentsJSON) {
            throw Self.error(
                "External message content cannot place links in calendar or reminder proposals. Nothing was executed.")
        }
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

        // Content-originated agent turns are an indirect prompt-injection
        // boundary. Only the narrow planning tools above can reach this point,
        // and every one needs a human even if globally whitelisted.
        let verdict: AutonomyPolicy.Verdict = sourceID != nil
            ? .requireConfirmation
            : policy.verdict(for: tool, connectorID: connectorID)
        switch verdict {
        case .requireConfirmation:
            let suggestion = Suggestion(
                title: "Aitvaras wants to run \(bareName)",
                detail: tool.description,
                connectorID: connectorID,
                toolName: bareName,
                argumentsJSON: call.argumentsJSON,
                causedBy: causedBy
            )
            try stores.offerSuggestion(
                suggestion,
                recording: ActivityEvent(
                    kind: .suggestionOffered,
                    connectorID: connectorID,
                    summary: "Awaiting confirmation: \(bareName)",
                    detailJSON: call.argumentsJSON,
                    causedBy: causedBy,
                    sourceID: sourceID))
            reporter?.begin(ActivityRun(id: suggestion.id, referenceID: suggestion.id.uuidString,
                category: .connection, state: .awaitingApproval, title: "Tool approval",
                stage: "Awaiting confirmation", executionLocation: "Not started",
                dataAccess: "Proposed connector action", dataDestination: connectorID))
            return .awaitingConfirmation(suggestion)

        case .allow:
            let output: String
            do {
                output = try await executeTracked(connector, connectorID: connectorID,
                    toolName: bareName, argumentsJSON: call.argumentsJSON, risk: tool.risk)
            } catch {
                let executionError = error
                do {
                    try stores.record(ActivityEvent(
                        kind: .toolExecuted,
                        connectorID: connectorID,
                        summary: "\(bareName) failed: \(executionError.localizedDescription)",
                        detailJSON: call.argumentsJSON,
                        causedBy: causedBy,
                        sourceID: sourceID))
                } catch {
                    throw Self.error(
                        "The action failed, and Aitvaras could not save that failure. \(executionError.localizedDescription)")
                }
                throw executionError
            }
            do {
                try stores.record(ActivityEvent(
                    kind: .toolExecuted,
                    connectorID: connectorID,
                    summary: "\(bareName): ok",
                    detailJSON: call.argumentsJSON,
                    causedBy: causedBy,
                    sourceID: sourceID))
                return .output(Self.boundedOutput(output))
            } catch {
                // The connector has already completed. Returning a warning as
                // tool output prevents the model from retrying a side effect
                // merely because its local audit write failed.
                return .output(Self.boundedOutput("""
                    \(output)

                    Warning: the action completed, but Aitvaras could not save its audit record. Do not retry it.
                    """))
            }
        }
    }

    /// Execute a previously-confirmed suggestion (user tapped accept).
    public func executeSuggestion(_ suggestion: Suggestion) async throws -> String {
        try Task.checkCancellation()
        reporter?.begin(ActivityRun(id: suggestion.id, referenceID: suggestion.id.uuidString,
            category: .connection, title: "Confirmed tool", stage: "Preparing approved action",
            executionLocation: "Local connector", dataAccess: "User-approved tool", dataDestination: suggestion.connectorID))
        reporter?.update(id: suggestion.id, stage: "Executing approved action", state: .running)
        do {
            let result = try await executeApprovedSuggestion(suggestion)
            reporter?.finish(id: suggestion.id, state: .succeeded, outcome: "Approved action completed")
            return result
        } catch {
            reporter?.finish(id: suggestion.id, state: .outcomeUnknown,
                outcome: "Action did not complete reliably; inspect before retrying")
            throw error
        }
    }

    private func executeApprovedSuggestion(_ suggestion: Suggestion) async throws -> String {
        guard let connector = connectors[suggestion.connectorID] else {
            _ = try stores.transitionSuggestion(
                suggestion.id, from: "pending", to: "failed",
                recording: ActivityEvent(
                    kind: .toolExecuted,
                    connectorID: suggestion.connectorID,
                    summary: "\(suggestion.toolName) failed: connector unavailable",
                    causedBy: suggestion.causedBy))
            throw Self.error("Connector \(suggestion.connectorID) is not available.")
        }

        guard suggestion.argumentsJSON.utf8.count <= Self.maximumToolArgumentsBytes else {
            _ = try stores.transitionSuggestion(
                suggestion.id, from: "pending", to: "failed",
                recording: ActivityEvent(
                    kind: .toolExecuted,
                    connectorID: suggestion.connectorID,
                    summary: "\(suggestion.toolName) refused: oversized stored arguments",
                    causedBy: suggestion.causedBy))
            throw Self.error(
                "This stored action contains oversized arguments and was not executed.")
        }

        let accepted = try stores.transitionSuggestion(
            suggestion.id, from: "pending", to: "accepted",
            recording: ActivityEvent(
                kind: .suggestionAccepted,
                connectorID: suggestion.connectorID,
                summary: "Accepted: \(suggestion.title)",
                causedBy: suggestion.causedBy))
        guard accepted else {
            throw Self.error("This suggestion was already handled.")
        }

        do {
            try Task.checkCancellation()
            let output = try await connector.execute(
                toolName: suggestion.toolName, argumentsJSON: suggestion.argumentsJSON)
            do {
                let recorded = try stores.transitionSuggestion(
                    suggestion.id, from: "accepted", to: "executed",
                    recording: ActivityEvent(
                        kind: .toolExecuted,
                        connectorID: suggestion.connectorID,
                        summary: "\(suggestion.toolName): ok (confirmed by user)",
                        detailJSON: suggestion.argumentsJSON,
                        causedBy: suggestion.causedBy))
                guard recorded else {
                    throw Self.error(
                        "The action ran, but its completion state changed unexpectedly. Do not run it again.",
                        completionRecording: true)
                }
            } catch {
                throw Self.error(
                    "The action ran, but Aitvaras could not save its completion record. Do not run it again. \(error.localizedDescription)",
                    completionRecording: true)
            }
            return Self.boundedOutput(output)
        } catch let executionError where !Self.isCompletionRecordingError(executionError) {
            do {
                _ = try stores.transitionSuggestion(
                    suggestion.id, from: "accepted", to: "failed",
                    recording: ActivityEvent(
                        kind: .toolExecuted,
                        connectorID: suggestion.connectorID,
                        summary: "\(suggestion.toolName) failed: \(executionError.localizedDescription)",
                        causedBy: suggestion.causedBy))
            } catch {
                throw Self.error(
                    "The action failed, and Aitvaras could not save that failure. \(executionError.localizedDescription)")
            }
            throw executionError
        }
    }

    public func rejectSuggestion(_ suggestion: Suggestion) throws {
        let rejected = try stores.transitionSuggestion(
            suggestion.id, from: "pending", to: "rejected",
            recording: ActivityEvent(
                kind: .suggestionRejected,
                connectorID: suggestion.connectorID,
                summary: "Rejected: \(suggestion.title)",
                causedBy: suggestion.causedBy))
        guard rejected else { throw Self.error("This suggestion was already handled.") }
        reporter?.finish(id: suggestion.id, state: .cancelled, outcome: "Proposal declined; no action taken")
    }

    private func executeTracked(_ connector: any Connector, connectorID: String,
                                toolName: String, argumentsJSON: String,
                                risk: ActionRisk) async throws -> String {
        try Task.checkCancellation()
        let runID = reporter?.begin(ActivityRun(category: .connection,
            title: "Tool: \(connectorID).\(toolName)", stage: "Executing",
            executionLocation: "Local connector", dataAccess: "Tool arguments and connector data",
            dataDestination: connectorID))
        return try await ActivityTaskContext.$runID.withValue(runID ?? ActivityTaskContext.runID) {
            do {
                guard ActivityExecution.permits(ActivityTaskContext.automaticFeature ?? .connectors,
                    stores: stores, reporter: reporter) else { throw CancellationError() }
                let output = try await connector.execute(toolName: toolName, argumentsJSON: argumentsJSON)
                if let runID { reporter?.finish(id: runID, state: .succeeded, outcome: "Tool completed") }
                try Task.checkCancellation()
                return output
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                if let runID { reporter?.finish(id: runID,
                    state: risk == .read ? (cancelled ? .cancelled : .failed) : .outcomeUnknown,
                    outcome: risk == .read ? "Tool stopped" : "Tool outcome is unknown; do not repeat automatically") }
                if cancelled { throw CancellationError() }
                throw error
            }
        }
    }

    /// Live merged event stream. Registrations and removals take effect
    /// immediately; callers never need to rebuild a snapshot after settings
    /// change while the app is running.
    public func mergedEvents() async -> AsyncStream<ConnectorEvent> {
        let pair = ConnectorEventStreams.make(
            bufferingOldest: ConnectorEventStreams.mergedCapacity)
        let id = UUID()
        eventContinuations[id] = pair.continuation
        pair.continuation.onTermination = { _ in
            Task { await self.removeEventContinuation(id) }
        }
        return pair.stream
    }

    private func broadcast(_ event: ConnectorEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private static let completionRecordingErrorDomain = "ConnectorHub.CompletionRecording"

    private static func error(_ message: String, completionRecording: Bool = false) -> NSError {
        NSError(
            domain: completionRecording ? completionRecordingErrorDomain : "ConnectorHub",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func isCompletionRecordingError(_ error: Error) -> Bool {
        (error as NSError).domain == completionRecordingErrorDomain
    }

    private static func boundedOutput(_ output: String) -> String {
        guard output.count > maximumToolOutputCharacters else { return output }
        return String(output.prefix(maximumToolOutputCharacters))
            + "\n…[tool output truncated; ask a narrower follow-up for more]"
    }
}
