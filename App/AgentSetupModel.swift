import Foundation
import Observation
import AppKit
import AitvarasAgents

/// View state only. Provider credentials, subprocesses and durable mutations
/// belong to the shared setup coordinator, never the SwiftUI view.
@MainActor @Observable
final class AgentSetupModel {
    let coordinator: AgentSetupCoordinator
    let projectID: UUID?
    let directory: URL?
    let accountChoices: [AgentProviderChoice]
    private var selectedAccounts: [AgentProvider: AgentProviderChoice]
    var provider: AgentProvider {
        didSet { if provider != oldValue { state = nil } }
    }
    var account: AgentProviderChoice {
        get { selectedAccounts[provider] ?? .init(provider: provider) }
        set {
            guard newValue != account, accountChoices.contains(newValue), newValue.provider == provider else { return }
            selectedAccounts[provider] = newValue
            state = nil
        }
    }
    private(set) var state: AgentSetupState?
    private(set) var busy = false
    private(set) var signingIn = false
    private(set) var message: String?
    private var operation: Task<Void, Never>?
    private var token = UUID()
    private var loadToken = UUID()
    var didChange: (() -> Void)?

    init(coordinator: AgentSetupCoordinator, projectID: UUID?, directory: URL?, claudeProfile: String = "default",
         accountChoices: [AgentProviderChoice]? = nil, preferred: [AgentProviderChoice] = []) {
        let choices = accountChoices ?? [.init(provider: .claude, profile: claudeProfile), .init(provider: .codex), .init(provider: .local)]
        self.accountChoices = choices
        self.selectedAccounts = Dictionary((preferred.filter { choices.contains($0) } + choices)
            .map { ($0.provider, $0) }, uniquingKeysWith: { first, _ in first })
        self.provider = preferred.first { choices.contains($0) }?.provider ?? choices.first?.provider ?? .local
        self.coordinator = coordinator; self.projectID = projectID; self.directory = directory
    }
    func load() async {
        let current = UUID(), selected = account
        loadToken = current
        if state?.provider != selected.provider { state = nil }
        do {
            let value = try await coordinator.state(projectID: projectID, directory: directory, provider: selected.provider, profile: selected.profile)
            try Task.checkCancellation()
            guard loadToken == current, account == selected else { return }
            state = value
        } catch { if loadToken == current, !Task.isCancelled { message = "Agent setup could not be loaded." } }
    }
    func checkNow() {
        guard let projectID, accountChoices.contains(account) else { return }
        perform {
            self.state = try await self.coordinator.refresh(projectID: projectID, directory: self.directory, provider: self.provider, profile: self.account.profile)
        }
    }
    func edit(_ edit: AgentSetupEdit) {
        guard let projectID else { return }
        perform {
            try await self.coordinator.edit(projectID: projectID, directory: self.directory, edit: edit)
            self.didChange?()
            await self.load()
            if self.provider != .local {
                do { self.state = try await self.coordinator.refresh(projectID: projectID, directory: self.directory, provider: self.provider, profile: self.account.profile) }
                catch { if !Task.isCancelled { self.message = "Settings saved. Provider status could not be checked." } }
            }
        }
    }
    func remove(_ row: AgentSetupServerRow) {
        perform {
            try await self.coordinator.removeServer(projectID: row.source == .global ? nil : self.projectID, name: row.name)
            self.didChange?(); await self.load()
        }
    }
    func save(_ draft: AgentMCPServerDraft) async -> Bool {
        guard !busy else { return false }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await coordinator.saveServer(projectID: projectID, directory: directory, draft: draft)
            didChange?(); await load(); return true
        } catch { message = Self.explanation(error); return false }
    }
    func signIn(_ row: AgentSetupServerRow) {
        guard !busy, let projectID else { return }
        signingIn = true
        perform {
            self.state = try await self.coordinator.signIn(projectID: projectID, directory: self.directory,
                provider: self.provider, profile: self.account.profile, rowID: row.id, onBrowserURL: Self.openBrowserURL)
            self.didChange?()
        }
    }
    func manageOnClaudeAI(_ row: AgentSetupServerRow) {
        guard provider == .claude, let projectID else { return }
        perform {
            try await self.coordinator.manageClaudeAccountConnector(projectID: projectID, directory: self.directory,
                profile: self.account.profile, rowID: row.id, onBrowserURL: Self.openBrowserURL)
        }
    }
    private nonisolated static func openBrowserURL(_ url: URL) async {
        guard !Task.isCancelled else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }
    func cancel() {
        token = UUID(); loadToken = UUID(); operation?.cancel(); operation = nil
        busy = false; signingIn = false
    }
    func cancelOperation() { operation?.cancel() }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        let current = UUID(); token = current; busy = true; message = nil
        operation = Task {
            defer { if token == current { busy = false; signingIn = false; operation = nil } }
            do { try await action() }
            catch { if token == current, !Task.isCancelled { message = Self.explanation(error) } }
        }
    }
    private static func explanation(_ error: Error) -> String {
        switch error {
        case AgentMCPError.nameCollision: "An app server and a repo server have the same name. Choose a different name."
        case AgentMCPError.invalidApproval: "The repo server changed. Check now and approve the current definition."
        case AgentMCPError.invalidName: "Choose a unique server name using letters, numbers, dots, underscores or hyphens."
        case let error as AgentMCPLoginError: error.localizedDescription
        case ProviderSignInError.timedOut: "Sign-in timed out. Try again."
        case AgentFailure.unsupported: "This provider does not report setup status here."
        case AgentFailure.notInstalled: "Install this provider to check its agent setup."
        default: "The operation could not be completed. Check the configuration and try again."
        }
    }
}
