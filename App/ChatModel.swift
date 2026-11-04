import Foundation
import Observation
import AitvarasCore
import AitvarasAgents
import AitvarasStore

/// Thin selection/composer adapter. The application manager owns every run,
/// including those whose chat is no longer visible.
@MainActor @Observable
final class ChatModel {
    let manager: AgentSessionManager
    private let stores: Stores
    private let backends: [AgentProvider: any AgentBackend]
    private var selection = ChatSelectionState()
    private var settings: [String: AgentChatSession] = [:]
    private var subscription: Task<Void, Never>?
    private var sending: Set<UUID> = []
    private var stoppedSends: Set<UUID> = []
    private(set) var state: ChatState?
    private(set) var error: String?
    private(set) var statuses: [AgentProvider: AgentStatus] = [:]

    init(manager: AgentSessionManager, stores: Stores, backends: [AgentProvider: any AgentBackend]) {
        self.manager = manager; self.stores = stores; self.backends = backends
    }
    var chatID: UUID? { selection.chatID }
    var provider: AgentProvider { selection.provider }
    var draft: String { get { selection.draft } set { selection.draft = newValue } }
    var isBusy: Bool { state?.isRunning == true || chatID.map { sending.contains($0) } == true }
    private var settingsKey: String { "\(chatID?.uuidString ?? "").\(provider.rawValue)" }
    var model: String {
        get { settings[settingsKey]?.model ?? (provider == .local ? "local" : "default") }
        set { settings[settingsKey]?.model = newValue }
    }
    var effort: String {
        get { settings[settingsKey]?.effort ?? "" }
        set { settings[settingsKey]?.effort = newValue.isEmpty ? nil : newValue }
    }
    var mode: AgentMode {
        get { settings[settingsKey]?.mode ?? .ask }
        set { settings[settingsKey]?.mode = newValue }
    }

    func select(_ id: UUID?) {
        guard id != chatID else { return }
        subscription?.cancel(); state = nil; error = nil
        do {
            let saved = try id.flatMap { try stores.value(forKey: "agent.provider.\($0.uuidString)") }
            selection.select(id, provider: saved.flatMap(AgentProvider.init(rawValue:)) ?? .local)
            try loadSettings()
            guard let id else { return }
            subscription = Task { [weak self, manager] in
                do {
                    for await state in try await manager.updates(chatID: id) {
                        guard !Task.isCancelled, self?.chatID == id else { return }
                        self?.state = state
                    }
                } catch { if self?.chatID == id { self?.error = "Chat history could not be loaded." } }
            }
        } catch { self.error = "Chat settings could not be loaded." }
    }

    func setProvider(_ value: AgentProvider) {
        guard let id = chatID, !isBusy else { return }
        do {
            try selection.select(id, provider: value) {
                try stores.setValues(["agent.provider.\(id.uuidString)": value.rawValue])
            }
            try loadSettings()
            error = nil
        } catch { self.error = "Provider selection could not be saved." }
    }

    private func loadSettings() throws {
        guard let id = chatID, settings[settingsKey] == nil,
              let chat = try stores.workspaceChat(id: id) else { return }
        let cwd = try stores.workspaceFolders(projectID: chat.projectID).first?.path
            ?? fallbackDirectory(id).path
        settings[settingsKey] = try stores.agentSession(chatID: id, provider: provider)
            ?? AgentChatSession(chatID: id, provider: provider, cwd: cwd,
                                model: provider == .local ? "local" : "default")
    }

    private func fallbackDirectory(_ id: UUID) -> URL {
        AitvarasPaths.stateDirectory.appendingPathComponent("AgentChats/\(id.uuidString)", isDirectory: true)
    }

    /// Status only. In particular Claude's models() starts a session, so it
    /// must never be called just because the Chat tab became visible.
    func refreshStatus() async {
        for provider in [AgentProvider.claude, .codex, .local] {
            statuses[provider] = try? await backends[provider]?.status()
        }
    }

    func send() async {
        guard let id = chatID, !isBusy, var session = settings[settingsKey],
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = draft; let provider = provider; let key = settingsKey
        sending.insert(id); error = nil
        defer { sending.remove(id); stoppedSends.remove(id) }
        do {
            guard let chat = try stores.workspaceChat(id: id), chat.archivedAt == nil,
                  let project = try stores.workspaceProject(id: chat.projectID), project.isVisible else {
                throw AgentFailure.invalidRequest
            }
            session.instructions = try stores.workspaceContextPacket(chatID: id).promptText
            // The manager may have bound a native identity since selection.
            session.sessionID = try stores.agentSession(chatID: id, provider: provider)?.sessionID
            if session.model == "default", let model = try await backends[provider]?.models().first {
                session.model = model.id
            }
            guard !stoppedSends.contains(id) else { return }
            guard try stores.workspaceChat(id: id)?.archivedAt == nil,
                  try stores.workspaceProject(id: chat.projectID)?.isVisible == true else {
                throw AgentFailure.invalidRequest
            }
            if session.cwd == fallbackDirectory(id).path {
                try FileManager.default.createDirectory(atPath: session.cwd, withIntermediateDirectories: true)
            } else {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &directory), directory.boolValue else {
                    throw AgentFailure.invalidRequest
                }
            }
            try await manager.configure(session)
            settings[key] = session
            guard !stoppedSends.contains(id) else { return }
            try await manager.send(chatID: id, provider: provider, input: .init(text: text))
            selection.clearDraft(chatID: id, ifUnchanged: text)
        } catch {
            if chatID == id, !stoppedSends.contains(id) { self.error = "Message could not be sent. Your draft is kept." }
        }
    }
    func stop() async {
        guard let id = chatID else { return }
        if sending.contains(id) { stoppedSends.insert(id) }
        do { try await manager.stop(chatID: id) }
        catch { self.error = "The response could not be stopped." }
    }
    func shutdown() async throws {
        stoppedSends.formUnion(sending)
        try await manager.shutdown()
        if let codex = backends[.codex] as? CodexBackend { try await codex.shutdown() }
    }
    func respond(to request: AgentRequest, with response: AgentResponse) async {
        guard let id = chatID else { return }
        do { try await manager.respond(chatID: id, to: request, with: response) }
        catch { self.error = "This request is no longer available." }
    }
}
