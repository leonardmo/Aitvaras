import SwiftUI
import AitvarasAgents

struct AgentSetupSection: View {
    @Environment(AppModel.self) private var model
    var projectID: UUID?
    var directory: URL? = nil
    @State private var setup: AgentSetupModel?

    var body: some View {
        Group {
            if let setup { AgentSetupContent(setup: setup) }
            else { ProgressView().controlSize(.small).accessibilityLabel("Loading agent setup") }
        }
        .task(id: "\(projectID?.uuidString ?? "global").\(directory?.path ?? "").\(model.agentSetupCoordinator != nil).\(model.chatModel?.claudeProfile ?? "default")") {
            setup?.cancel()
            guard let coordinator = model.agentSetupCoordinator else { return }
            let value = AgentSetupModel(coordinator: coordinator, projectID: projectID, directory: directory, claudeProfile: model.chatModel?.claudeProfile ?? "default")
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
    @State private var addingServer = false
    @State private var expandedCommandGroups = Set(AgentCommand.Group.allCases.filter(\.initiallyExpanded))

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if setup.projectID != nil {
                Picker("Provider", selection: $setup.provider) {
                    Text("Claude").tag(AgentProvider.claude)
                    Text("Codex").tag(AgentProvider.codex)
                    Text("Local").tag(AgentProvider.local)
                }.pickerStyle(.segmented).disabled(setup.busy)
                    .accessibilityIdentifier("agent.setup.provider")
            }
            HStack {
                Text("MCP servers").font(.headline)
                Spacer()
                if setup.busy { ProgressView().controlSize(.small) }
                if setup.projectID != nil {
                    Button("Check now", systemImage: "arrow.clockwise") { setup.checkNow() }
                        .disabled(setup.busy).accessibilityIdentifier("agent.setup.check")
                }
                if setup.provider != .codex {
                    Button("Add server…", systemImage: "plus") { addingServer = true }
                        .disabled(setup.busy).accessibilityIdentifier("agent.setup.add")
                }
            }
            if setup.state?.servers.isEmpty == true {
                Text(setup.provider == .codex ? "Check now to discover provider MCP servers." : "No MCP servers defined.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(setup.state?.servers ?? []) { row in serverRow(row) }
            if setup.signingIn {
                Button("Cancel sign-in") { setup.cancelOperation() }.accessibilityIdentifier("agent.setup.cancelSignIn")
            }
            ForEach(setup.state?.notices ?? [], id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let message = setup.message { Text(message).font(.caption).foregroundStyle(.orange) }
            if let state = setup.state, setup.projectID != nil {
                Divider()
                policy(state)
                if setup.provider == .claude { metadata(state.snapshot); catalog(state.snapshot) }
            }
        }
        .accessibilityIdentifier("agent.setup")
        .task(id: setup.provider) { await setup.load() }
        .sheet(isPresented: $addingServer) { AgentMCPServerForm(setup: setup) }
    }

    private func serverRow(_ row: AgentSetupServerRow) -> some View {
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
            if row.canManageOnClaudeAI {
                Button("Manage on claude.ai") { setup.manageOnClaudeAI(row) }
                    .disabled(setup.busy)
                    .accessibilityIdentifier("agentSetup.manageOnClaudeAI.\(row.name)")
            } else {
                if row.indicator == .needsSignIn, row.canSignIn {
                    Button("Sign in") { setup.signIn(row) }
                        .disabled(setup.busy)
                        .accessibilityIdentifier("agentSetup.signIn.\(row.name)")
                }
                Menu {
                    if row.isApproved { Button("Revoke approval") { setup.edit(.revoke(name: row.name)) } }
                    if row.canApprove, let fingerprint = row.fingerprint {
                        Button("Approve") { setup.edit(.approve(name: row.name, fingerprint: fingerprint)) }
                    }
                    if row.canDeny { Button("Deny") { setup.edit(.deny(name: row.name)) } }
                    Button("Sign in") { setup.signIn(row) }.disabled(!row.canSignIn)
                        .help(row.signInUnavailable ?? "Sign in using the provider CLI")
                    if row.source == .global, setup.projectID != nil {
                        Button(row.isOffInProject ? "On in this project" : "Off in this project") {
                            setup.edit(.globalEnabled(name: row.name, enabled: row.isOffInProject))
                        }
                    }
                    if row.canRemove { Button("Remove", role: .destructive) { setup.remove(row) } }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Actions for \(row.name)") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(setup.busy)
                    .accessibilityIdentifier("agent.setup.server.\(row.id).actions")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.setup.server.\(row.id)")
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

private struct AgentMCPServerForm: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var setup: AgentSetupModel
    @State private var draft = AgentMCPServerDraft()
    @State private var saving: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add MCP server").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Server name", text: $draft.name)
                    Picker("Transport", selection: $draft.transport) {
                        Text("stdio").tag(AgentMCPServer.Transport.stdio)
                        Text("HTTP").tag(AgentMCPServer.Transport.http)
                        Text("SSE").tag(AgentMCPServer.Transport.sse)
                    }.pickerStyle(.menu)
                    if draft.transport == .stdio {
                        TextField("Command", text: $draft.command)
                        Text("Arguments · one per line").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft.arguments).font(.body.monospaced()).frame(height: 70)
                        Text("Environment").font(.headline)
                    } else {
                        TextField("URL", text: $draft.url)
                        Text("Headers").font(.headline)
                    }
                    ForEach($draft.fields) { $field in
                        HStack(alignment: .center, spacing: 8) {
                            TextField("Name", text: $field.name).frame(width: 125)
                            if field.secret { SecureField("Value", text: $field.value) }
                            else { TextField("Value", text: $field.value) }
                            Toggle("Secret", isOn: $field.secret).toggleStyle(.switch).controlSize(.small)
                            Button { draft.fields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).accessibilityLabel("Remove field")
                        }
                    }
                    Button(draft.transport == .stdio ? "Add environment variable" : "Add header") { draft.fields.append(.init()) }
                    Text("Secret values are stored in this profile's Keychain. Put credentials in secret fields, not in the URL, command or arguments.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = setup.message { Text(message).font(.caption).foregroundStyle(.orange) }
                }.textFieldStyle(.roundedBorder).padding(2)
            }.disabled(setup.busy)
            HStack {
                if setup.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { saving?.cancel(); draft = .init(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = Task { if await setup.save(draft) { draft = .init(); dismiss() }; saving = nil }
                }.buttonStyle(.borderedProminent).disabled(setup.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 580, height: 490)
            .accessibilityIdentifier("agent.setup.serverForm")
            .onChange(of: draft.transport) { old, new in
                if (old == .stdio) != (new == .stdio) { draft.fields = []; draft.command = ""; draft.arguments = ""; draft.url = "" }
            }
            .onDisappear { saving?.cancel(); draft = .init() }
    }
}
