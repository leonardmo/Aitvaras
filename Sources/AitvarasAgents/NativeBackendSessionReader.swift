import Foundation
import AitvarasCore

/// Compatibility projection for saved native-evidence views. Reading through
/// the new backends changes no evidence ownership or import policy.
public actor NativeBackendSessionReader: NativeSessionReader {
    public nonisolated let provider: NativeSessionProvider
    private let backend: (any AgentBackend)?
    private var summaries: [String: AgentSessionSummary] = [:]
    public init(provider: NativeSessionProvider, backend: (any AgentBackend)?) {
        self.provider = provider; self.backend = backend
    }
    public func capabilities() async -> NativeSessionCapability {
        do {
            guard let backend else { throw AgentFailure.offline }
            _ = try await backend.nativeSessions(folder: nil, cursor: nil, archived: false)
            return .init(provider: provider, state: .ready,
                         version: provider == .claude ? ClaudeNativeHistory.formatVersion : "app-server thread/list + thread/read",
                         detail: "Local native text history")
        } catch {
            return .init(provider: provider, state: (error as? AgentFailure) == .notInstalled ? .missingRuntime : .unavailable,
                         detail: "Local native history is unavailable.")
        }
    }
    public func listSessions(cursor: String?, archived: Bool) async throws -> NativeSessionPage {
        guard let backend else { throw AgentFailure.offline }
        let page = try await backend.nativeSessions(folder: nil, cursor: cursor, archived: archived)
        for item in page.items { summaries[item.id.nativeID] = item }
        return .init(sessions: page.items.map { value in
            .init(provider: provider, hostID: value.id.host, externalID: value.id.nativeID,
                  title: value.title, directory: value.directory.path, archived: value.archived)
        }, nextCursor: page.nextCursor, coverage: "Local native sessions")
    }
    public func readSession(id: String, directory: String?, cursor: String?) async throws -> NativeTranscriptPage {
        // Saved evidence may be refreshed without first listing the browser.
        let identity = summaries[id]?.id ?? AgentSessionID(provider: provider == .claude ? .claude : .codex,
                                                          profile: "default", nativeID: id)
        guard let backend else { throw AgentFailure.offline }
        let page = try await backend.readHistory(session: identity, cursor: cursor)
        let summary = summaries[id]
        let messages: [NativeTextMessage] = page.items.compactMap { event in
            guard case .message(let id, let role, let text) = event.kind,
                  let role = NativeTextMessage.Role(rawValue: role) else { return nil }
            return .init(externalID: id, role: role, text: text)
        }
        return .init(session: .init(provider: provider, externalID: id, title: summary?.title ?? "Chat",
                                   directory: summary?.directory.path ?? directory), messages: messages, nextCursor: page.nextCursor,
                     coverage: summary?.sourceVersion ?? "Local native text history", direction: .newer)
    }
}
