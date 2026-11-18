import Foundation
import AitvarasCore

public struct AgentConversationSource: Sendable, Equatable {
    public let chatID: UUID
    public let projectID: UUID
    public let title: String
    public let session: AgentChatSession
    public let entries: [AgentTranscriptEntry]
    public let completedIDs: Set<UUID>
    public let worktree: AgentWorktree?
    public init(chatID: UUID, projectID: UUID, title: String, session: AgentChatSession,
                entries: [AgentTranscriptEntry], completedIDs: Set<UUID>, worktree: AgentWorktree?) {
        self.chatID = chatID; self.projectID = projectID; self.title = title; self.session = session
        self.entries = entries; self.completedIDs = completedIDs; self.worktree = worktree
    }
}

public struct AgentConversationForkPlan: Sendable, Equatable {
    public let source: AgentConversationSource
    public let prefix: [AgentTranscriptEntry]
    public let origin: AgentForkOrigin?
    public static func make(source: AgentConversationSource, messageID: UUID, editing: Bool) throws -> Self {
        guard let index = source.entries.firstIndex(where: { $0.id == messageID }), source.session.provider == .claude else { throw AgentConversationError.invalidMessage }
        let selected = source.entries[index]
        guard selected.provider == .claude, selected.sessionID == source.session.id else { throw AgentConversationError.unavailable }
        var anchor = index
        if editing {
            guard selected.kind == "user" else { throw AgentConversationError.invalidMessage }
            guard let previous = source.entries[..<index].lastIndex(where: { $0.kind == "assistant" }) else {
                return .init(source: source, prefix: [], origin: nil)
            }
            anchor = previous
        }
        let entry = source.entries[anchor]
        guard entry.kind == "assistant", entry.provider == .claude, entry.sessionID == source.session.id,
              source.completedIDs.contains(entry.id), let message = entry.nativeMessageID, UUID(uuidString: message) != nil,
              let native = source.session.sessionID, UUID(uuidString: native.nativeID) != nil else { throw AgentConversationError.unavailable }
        return .init(source: source, prefix: Array(source.entries[...anchor]),
            origin: .init(chatID: source.chatID, sessionID: source.session.id, native: native, assistantMessageID: message))
    }
}

public protocol AgentConversationPersistence: Sendable {
    func conversationSource(chatID: UUID) throws -> AgentConversationSource
    func createConversationFork(_ plan: AgentConversationForkPlan, chatID: UUID, directory: URL,
                                additionalRoots: [URL]) throws
    func finishConversationFork(chatID: UUID, worktree: AgentWorktree) throws
}

public struct AgentConversationForkResult: Sendable {
    public let chatID: UUID
    public let input: AgentInput?
}

/// User-invoked conversation operations. Side-question text never crosses the
/// persistence or audit interfaces, and normal chat runs remain untouched.
public actor AgentConversationActions {
    private let persistence: any AgentConversationPersistence
    private let git: AgentGitActionCoordinator
    private let backend: AgentSessionManager.BackendFactory
    private let audit: AgentActionCoordinator.Audit
    private let worktreeStorage: URL
    private var forks: [UUID: Task<AgentConversationForkResult, Error>] = [:]
    private var questions: [UUID: Task<String, Error>] = [:]
    private var closing = false
    public init(persistence: any AgentConversationPersistence, git: AgentGitActionCoordinator,
                worktreeStorage: URL, backend: @escaping AgentSessionManager.BackendFactory,
                audit: @escaping AgentActionCoordinator.Audit) {
        self.persistence = persistence; self.git = git; self.worktreeStorage = worktreeStorage
        self.backend = backend; self.audit = audit
    }

    public func fork(chatID: UUID, messageID: UUID, editedText: String? = nil) async throws -> AgentConversationForkResult {
        guard !closing, forks[chatID] == nil else { throw AgentConversationError.busy }
        let task = Task { try await performFork(chatID: chatID, messageID: messageID, editedText: editedText) }
        forks[chatID] = task
        defer { forks.removeValue(forKey: chatID) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func performFork(chatID: UUID, messageID: UUID, editedText: String?) async throws -> AgentConversationForkResult {
        let source = try persistence.conversationSource(chatID: chatID)
        let plan = try AgentConversationForkPlan.make(source: source, messageID: messageID, editing: editedText != nil)
        if let text = editedText {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_048_576,
                  !text.contains("\0") else { throw AgentFailure.invalidRequest }
        }
        let input = try editedText.map { text in
            try AgentInput.restoring(id: UUID(), text: text, payload: source.entries.first { $0.id == messageID }?.payloadJSON)
        }
        let id = UUID()
        let destination = worktreeStorage.resolvingSymlinksInPath().appendingPathComponent(id.uuidString)
        func map(_ path: String) -> URL {
            guard let owned = source.worktree else { return URL(fileURLWithPath: path) }
            if path == owned.worktreePath { return destination }
            if path.hasPrefix(owned.worktreePath + "/") { return destination.appendingPathComponent(String(path.dropFirst(owned.worktreePath.count + 1))) }
            return URL(fileURLWithPath: path)
        }
        if let owned = source.worktree {
            guard source.session.cwd == owned.worktreePath || source.session.cwd.hasPrefix(owned.worktreePath + "/") else { throw AgentGitError.ownershipConflict }
            try await git.requireCleanForFork(chatID: chatID)
        }
        let roots = try JSONDecoder().decode([String].self, from: Data(source.session.additionalRootsJSON.utf8)).map(map)
        try Task.checkCancellation()
        try persistence.createConversationFork(plan, chatID: id, directory: map(source.session.cwd), additionalRoots: roots)
        if source.worktree != nil {
            do {
                let owned = try await git.fork(chatID: id, sourceChatID: chatID, projectID: source.projectID, storage: worktreeStorage)
                try persistence.finishConversationFork(chatID: id, worktree: owned)
            } catch { throw AgentConversationError.worktreeUnavailable(id) }
        }
        return .init(chatID: id, input: input)
    }

    public func sideQuestion(chatID: UUID, question: String, timeout: Duration = .seconds(120)) async throws -> String {
        guard !closing, questions[chatID] == nil else { throw AgentConversationError.busy }
        let source = try persistence.conversationSource(chatID: chatID)
        guard source.session.sessionID != nil, source.session.forkOrigin?.pending != true else { throw AgentConversationError.unavailable }
        let tool = ToolDefinition(name: "sideQuestion", description: "Read conversation context", parametersJSON: "{}", risk: .read)
        guard AutonomyPolicy().verdict(for: tool, connectorID: "agent.conversation") == .allow else { throw AgentFailure.invalidRequest }
        try await audit(.init(kind: .toolExecuted, connectorID: "agent.conversation", summary: "Side question requested", sourceID: "chat:" + chatID.uuidString))
        try Task.checkCancellation()
        guard !closing, questions[chatID] == nil else { throw AgentConversationError.busy }
        let provider = try backend(.claude), configuration = source.session.configuration
        let task = Task { try await provider.sideQuestion(configuration: configuration, question: question, timeout: timeout) }
        questions[chatID] = task
        defer { questions.removeValue(forKey: chatID) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func shutdown() async {
        closing = true
        let tasks = Array(questions.values)
        let forkTasks = Array(forks.values)
        tasks.forEach { $0.cancel() }
        forkTasks.forEach { $0.cancel() }
        for task in tasks { _ = try? await task.value }
        for task in forkTasks { _ = try? await task.value }
        closing = false
    }
}
