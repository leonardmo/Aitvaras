import SwiftUI
import AitvarasAgents

struct AgentSetupSection: View {
    @Environment(AppModel.self) private var model
    var projectID: UUID?
    var directory: URL? = nil
    var showsServerDefinitions = true
    var serversOnly = false
    @State private var setup: AgentSetupModel?

    var body: some View {
        Group {
            if let setup {
                AgentSetupContent(setup: setup, accountTitle: { model.chatModel?.title($0) ?? $0.provider.rawValue.capitalized }, showsServerDefinitions: showsServerDefinitions, serversOnly: serversOnly)
            }
            else { ProgressView().controlSize(.small).accessibilityLabel("Loading agent setup") }
        }
        .task(id: "\(projectID?.uuidString ?? "global").\(directory?.path ?? "").\(model.agentSetupCoordinator != nil).\(model.chatModel?.choice.id ?? "").\(model.chatModel?.allChoices.map(\.id).joined(separator: ",") ?? "")") {
            setup?.cancel()
            guard let coordinator = model.agentSetupCoordinator else { return }
            let chat = model.chatModel
            let preferred = chat.map { [$0.choice, $0.effectiveChoice(.claude), $0.effectiveChoice(.codex)] } ?? []
            let value = AgentSetupModel(coordinator: coordinator, projectID: projectID, directory: directory,
                accountChoices: chat?.allChoices ?? [], preferred: preferred)
            value.didChange = { [weak model] in model?.chatModel?.invalidateCommandCatalog() }
            setup = value
            await value.load()
        }
        .task(id: model.chatModel?.agentSetupRevision) { await setup?.load() }
        .onDisappear { setup?.cancel() }
    }
}

private struct AgentSetupContent: View {
    @Bindable var setup: AgentSetupModel
    let accountTitle: (AgentProviderChoice) -> String
    let showsServerDefinitions: Bool
    let serversOnly: Bool
    @State private var removingServer: AgentSetupServerRow?
    @State private var expandedCommandGroups = Set(AgentCommand.Group.allCases.filter(\.initiallyExpanded))

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if setup.projectID != nil, !setup.accountChoices.isEmpty {
                let providers = [AgentProvider.claude, .codex, .local].filter { kind in
                    setup.accountChoices.contains { $0.provider == kind }
                }
                Picker("Provider", selection: $setup.provider) {
                    ForEach(providers, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.segmented).disabled(setup.busy)
                    .accessibilityIdentifier("agent.setup.provider")
                let accounts = setup.accountChoices.filter { $0.provider == setup.provider }
                if accounts.count > 1 {
                    Picker("Account", selection: $setup.account) {
                        ForEach(accounts) { Text(accountTitle($0)).tag($0) }
                    }.disabled(setup.busy)
                }
            }
            HStack {
                Text(showsServerDefinitions ? "Provider-managed servers" : "Provider state").font(.headline)
                Spacer()
                if setup.busy { ProgressView().controlSize(.small) }
                if setup.projectID != nil {
                    Button("Check now", systemImage: "arrow.clockwise") { setup.checkNow() }
                        .disabled(setup.busy || setup.accountChoices.isEmpty).accessibilityIdentifier("agent.setup.check")
                }
            }
            if showsServerDefinitions {
                if setup.state?.servers.isEmpty == true {
                    Text(setup.provider == .codex ? "Check now to discover provider MCP servers." : "No provider-managed servers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(setup.state?.servers ?? []) { row in serverRow(row) }
                if setup.signingIn {
                    Button("Cancel sign-in") { setup.cancelOperation() }.accessibilityIdentifier("agent.setup.cancelSignIn")
                }
            }
            ForEach(setup.state?.notices ?? [], id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let message = setup.message { Text(message).font(.caption).foregroundStyle(.orange) }
            if !serversOnly, let state = setup.state, setup.projectID != nil {
                Divider()
                policy(state)
                if setup.provider == .claude { metadata(state.snapshot); catalog(state.snapshot) }
            }
        }
        .accessibilityIdentifier("agent.setup")
        .task(id: setup.account) { await setup.load() }
        .confirmationDialog("Remove MCP server?",
                            isPresented: Binding(get: { removingServer != nil }, set: { if !$0 { removingServer = nil } }),
                            presenting: removingServer) { row in
            Button("Remove server", role: .destructive) { setup.remove(row) }
        } message: { row in
            Text("Remove \(row.name) from Aitvaras-managed server settings.")
        }
    }

    private func serverRow(_ row: AgentSetupServerRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                AgentSetupStatusIndicator(status: row.indicator).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name).font(.callout.weight(.medium)).lineLimit(2)
                    Text(row.sourceLabel).font(.caption).foregroundStyle(.secondary)
                    if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    if row.source == .project || row.source == .global, let reason = row.signInUnavailable {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 7) {
                serverActions(row)
            }
            .controlSize(.small)
            .disabled(setup.busy)
            .padding(.leading, 18)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.setup.server.\(row.id)")
    }

    @ViewBuilder private func serverActions(_ row: AgentSetupServerRow) -> some View {
        if row.canManageOnClaudeAI {
            Button("Manage on claude.ai") { setup.manageOnClaudeAI(row) }
                .accessibilityIdentifier("agentSetup.manageOnClaudeAI.\(row.name)")
        } else {
            if row.canSignIn {
                Button("Sign in") { setup.signIn(row) }
                    .accessibilityIdentifier("agentSetup.signIn.\(row.name)")
            }
            if row.isApproved { Button("Revoke approval") { setup.edit(.revoke(name: row.name)) } }
            if row.canApprove, let fingerprint = row.fingerprint {
                Button("Approve") { setup.edit(.approve(name: row.name, fingerprint: fingerprint)) }
            }
            if row.canDeny { Button("Deny") { setup.edit(.deny(name: row.name)) } }
            if row.source == .global, setup.projectID != nil {
                Button(row.isOffInProject ? "Enable in this project" : "Disable in this project") {
                    setup.edit(.globalEnabled(name: row.name, enabled: row.isOffInProject))
                }
                Button("Shared server settings", systemImage: "arrow.up.right") {
                    SettingsNavigation.open(.page(.connections), settingID: "connections.servers")
                }.buttonStyle(.link)
            } else if row.canRemove {
                Button("Remove", role: .destructive) { removingServer = row }
            }
        }
    }

    @ViewBuilder private func policy(_ state: AgentSetupState) -> some View {
        if setup.provider == .claude {
            Text("Permission source").font(.headline)
            Picker("Permission source", selection: Binding(get: { state.permissionSource }, set: { setup.edit(.permissionSource($0)) })) {
                Text("Repo settings").tag(AgentPermissionSource.repo)
                Text("Aitvaras policy").tag(AgentPermissionSource.aitvaras)
            }.pickerStyle(.menu).disabled(setup.busy).accessibilityIdentifier("agent.setup.permissionSource")
            Text("Repo settings: the repo's allow and deny rules apply.").font(.caption).foregroundStyle(.secondary)
            Text("Aitvaras policy: Aitvaras decides every approval; the repo's allow rules are ignored, its deny rules and hooks still apply.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if setup.provider == .local {
            Toggle("Local may use MCP servers", isOn: Binding(get: { state.localMayUseMCP }, set: { setup.edit(.localMayUseMCP($0)) }))
                .toggleStyle(.switch).disabled(setup.busy).accessibilityIdentifier("agent.setup.localMCP")
            Text("Local: stdio servers only").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func catalog(_ snapshot: AgentSetupSnapshot?) -> some View {
        Text("Skills and commands").font(.headline)
        let names = Set((snapshot?.commands ?? []).map(\.name))
        let skills = (snapshot?.skills ?? []).filter { !names.contains($0) }.map { AgentCommand(name: $0, description: "") }
        let commands = AgentCommandCatalog.withConversationCommands((snapshot?.commands ?? []) + skills)
        ForEach(AgentCommand.Group.allCases) { group in
            let values = commands.filter { (snapshot?.metadata.commandSources ?? .init()).group(for: $0) == group }
            if !values.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedCommandGroups.contains(group) },
                    set: { if $0 { expandedCommandGroups.insert(group) } else { expandedCommandGroups.remove(group) } }
                )) { commandRows(values) } label: {
                    Text(group.rawValue + " (\(values.count))").font(.subheadline)
                }
            }
        }
        if snapshot?.commandsAvailable != true { Text("The command catalog has not been reported. Check now to refresh.").font(.caption).foregroundStyle(.secondary) }
        if let agents = snapshot?.agents, !agents.isEmpty {
            DisclosureGroup("Agents (\(agents.count))") {
                ForEach(agents, id: \.self) { Text($0).font(.callout).lineLimit(1) }
            }
        }
    }
    private func commandRows(_ commands: [AgentCommand]) -> some View {
        ForEach(commands) { command in
            HStack(spacing: 8) {
                Text(command.insertion).font(.callout.monospaced()).lineLimit(1)
                if let hint = command.argumentHint { Text(hint).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                Text(command.description).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }.help(command.description).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func metadata(_ snapshot: AgentSetupSnapshot?) -> some View {
        Text("Hooks").font(.headline)
        ForEach(Array((snapshot?.metadata.hooks ?? []).enumerated()), id: \.offset) { _, hook in
            VStack(alignment: .leading, spacing: 2) {
                Text(hook.event + (hook.matcher.map { " · " + $0 } ?? "")).font(.callout.monospaced())
                if let message = hook.statusMessage { Text(message).font(.caption) }
                Text(hook.source).font(.caption).foregroundStyle(.secondary)
            }
        }
        Text("Rules files").font(.headline)
        ForEach(Array((snapshot?.metadata.rules ?? []).enumerated()), id: \.offset) { _, rule in
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).font(.callout.monospaced())
                if !rule.paths.isEmpty { Text("paths: " + rule.paths.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct AgentSetupStatusIndicator: View {
    let status: AgentSetupServerRow.Indicator
    private var color: Color {
        switch status { case .connected: .green; case .needsSignIn: .yellow; case .failed: .red; default: .gray }
    }
    private var label: String {
        switch status {
        case .connected: "Connected"; case .needsSignIn: "Needs sign-in"; case .off: "Off"
        case .approved: "Approved, starts with the next chat"; case .pendingApproval: "Pending approval"; case .pending: "Pending"; case .failed: "Failed"; case .unknown: "Status not reported"
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityLabel(label).help(label)
    }
}
