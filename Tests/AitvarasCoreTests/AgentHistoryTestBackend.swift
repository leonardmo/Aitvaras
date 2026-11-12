import Foundation
import AitvarasAgents
import AitvarasStore

/// Existing lifecycle/Stop scripts model transport, not native disk storage.
/// Supply their journal as a deterministic history fixture while forwarding all
/// run operations to the same real process. Native read/resume contracts are
/// exercised separately in AgentHistoryReconciliationTests.
actor AgentHistoryTestBackend: AgentBackend {
    let backend: any AgentBackend
    let stores: Stores
    init(_ backend: any AgentBackend, stores: Stores) { self.backend = backend; self.stores = stores }
    func status() async throws -> AgentStatus { try await backend.status() }
    func models() async throws -> [AgentModel] { try await backend.models() }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws { try await backend.signIn(onBrowserURL: onBrowserURL) }
    func start(_ configuration: AgentSessionConfiguration) async throws -> any AgentRun { try await backend.start(configuration) }
    func listSessions(folder: URL, cursor: String?) async throws -> AgentPage<AgentSessionSummary> { try await backend.listSessions(folder: folder, cursor: cursor) }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> {
        let chats = try stores.recentWorkspaceChats(limit: 200)
        for chat in chats {
            guard let saved = try stores.agentSession(chatID: chat.id, provider: session.provider), saved.sessionID == session else { continue }
            let entries = try stores.agentEntries(chatID: chat.id).filter { $0.sessionID == saved.id && ["user", "assistant"].contains($0.kind) }
            let events = entries.map { entry in
                let id = entry.nativeMessageID ?? entry.id.uuidString
                return AgentEvent(scope: .init(runID: UUID(), session: session, itemID: id), kind: .message(id: id, role: entry.kind, text: entry.text))
            }
            return .init(items: events)
        }
        return .init(items: [])
    }
}
