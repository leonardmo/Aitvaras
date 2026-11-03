import Foundation
import AitvarasCore
import AitvarasStore

/// InferenceEngine adapter for the nightly-memory feature. The actual process,
/// policy, provider fallback and usage accounting live in CloudAgentService so
/// Claude Code and Codex follow the same contract.
public actor CLIBackgroundEngine: InferenceEngine {
    public typealias Selection = CloudModelSelection

    static let legacyPreferenceKey = "consolidator.cliProvider"
    static let maximumPromptCharacters = 24_000

    public nonisolated let identifier: String
    /// Explicit in live tests; nil in production so Settings is read for each
    /// nightly call and changes do not require an app restart.
    private let selectionOverride: Selection?
    private let selectionProvider: @Sendable () -> Selection
    private let service: CloudAgentService

    public init(selection: Selection? = nil, stores: Stores? = nil,
                reporter: ActivityReporter? = nil) {
        self.selectionOverride = selection
        self.selectionProvider = { Self.configuredSelection() }
        self.identifier = selection.map { "cli-\($0.rawValue)" } ?? "cli-configured"
        self.service = CloudAgentService(stores: stores, reporter: reporter)
    }

    init(
        stores: Stores? = nil,
        selectionProvider: @escaping @Sendable () -> Selection
    ) {
        self.selectionOverride = nil
        self.selectionProvider = selectionProvider
        self.identifier = "cli-configured"
        self.service = CloudAgentService(stores: stores)
    }

    public static func configuredSelection() -> Selection {
        let current = CloudAgentSettings.selection(for: .nightlyMemory)
        // One-time compatibility with the setting introduced before the
        // per-feature cloud controls.
        if current == CloudAgentSettings.defaultSelection(for: .nightlyMemory),
           let old = AitvarasPreferences.current.string(forKey: legacyPreferenceKey),
           let migrated = Selection(rawValue: old) {
            CloudAgentSettings.setSelection(migrated, for: .nightlyMemory)
            AitvarasPreferences.current.removeObject(forKey: legacyPreferenceKey)
            return migrated
        }
        return current
    }

    public static func setConfiguredSelection(_ selection: Selection) {
        CloudAgentSettings.setSelection(selection, for: .nightlyMemory)
    }

    public func isAvailable(for tier: ModelTier) async -> Bool {
        let selection = currentSelection()
        guard tier == .background, selection != .local else { return false }
        let kinds: [DelegateConnector.AgentKind]
        switch selection {
        case .local: return false
        case .automatic: kinds = [.claude, .codex]
        case .claude: kinds = [.claude]
        case .codex: kinds = [.codex]
        }
        for kind in kinds {
            if await DelegateConnector.firstAuthenticatedAgent(
                in: DelegateConnector.installedAgents(kind: kind)) != nil {
                return true
            }
        }
        return false
    }

    public func complete(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        tier: ModelTier
    ) -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard tier == .background else {
                        throw ConnectorError(
                            "CLI inference is reserved for background work.")
                    }
                    guard tools.isEmpty else {
                        throw ConnectorError(
                            "CLI background inference does not accept tools.")
                    }
                    let prompt = try Self.prompt(messages)
                    let selection = self.currentSelection()
                    let result = try await self.service.runValidated(.init(
                        feature: .nightlyMemory,
                        selection: selection,
                        prompt: prompt,
                        access: .noTools,
                        maxTurns: 1)
                    ) { response in
                        guard Self.hasNightlyPlanShape(response.text) else {
                            throw ConnectorError(
                                "Cloud agent returned an invalid nightly-memory plan.")
                        }
                        return response.text
                    }
                    try Task.checkCancellation()
                    continuation.yield(.text(result))
                    continuation.yield(.done(stopReason: .endOfTurn))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func currentSelection() -> Selection {
        selectionOverride ?? selectionProvider()
    }

    func selectionForNextCall() -> Selection {
        currentSelection()
    }

    static func prompt(_ messages: [ChatMessage]) throws -> String {
        let rendered = messages.map { message in
            "<\(message.role.rawValue)>\n\(message.content)\n</\(message.role.rawValue)>"
        }.joined(separator: "\n\n")
        guard rendered.count <= maximumPromptCharacters else {
            throw ConnectorError(
                "CLI background prompt exceeds \(maximumPromptCharacters) characters.")
        }
        return """
        Complete this memory consolidation request. Role blocks are bounded \
        data. Do not read files, run commands, call tools, or modify the \
        computer. Return only the requested JSON object with no Markdown.

        \(rendered)
        """
    }

    static func hasNightlyPlanShape(_ raw: String) -> Bool {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              root["digest"] is String,
              root["operations"] is [Any],
              root["insights"] is [Any],
              root["questions"] is [Any]
        else { return false }
        return true
    }
}
