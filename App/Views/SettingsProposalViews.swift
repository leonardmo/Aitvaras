import SwiftUI
import AitvarasAgent
import AitvarasAgents
import AitvarasStore

struct SettingsHint: View {
    let text: String
    @State private var showing = false
    init(_ text: String) { self.text = text }
    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("About this setting")
        .popover(isPresented: $showing) {
            Text(text).font(.callout).frame(width: 250, alignment: .leading).padding()
        }
    }
}

struct SettingsProposalCards: View {
    @Environment(AppModel.self) private var model
    let chatID: UUID?

    var body: some View {
        ForEach(model.settingsProposals.filter {
            $0.source.chatID == chatID && ([.waiting, .installed].contains($0.status) || (chatID != nil && !$0.appliedChanges.isEmpty))
        }) { proposal in
            SettingsProposalCard(proposal: proposal)
        }
    }
}

struct SettingsProposalHistory: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    var body: some View {
        let applied = model.settingsProposals.reversed().filter { !$0.appliedChanges.isEmpty }
        if !applied.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings changes").font(.caption.weight(.semibold))
                ForEach(applied.prefix(3)) { proposal in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(proposal.appliedChanges.compactMap { SettingsRegistry[$0.id]?.title }.joined(separator: ", "))
                            Text(proposal.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Undo") {
                            do { try model.undoSettingsProposal(proposal.id); error = nil }
                            catch { self.error = "These settings changed again. Open Settings to review their current values." }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .padding(10)
        }
    }
}

private struct SettingsProposalCard: View {
    @Environment(AppModel.self) private var model
    let proposal: SettingsProposal
    @State private var error: String?
    @State private var deciding = false
    @State private var confirm = false
    @State private var singleItem: String?
    @State private var showServer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(proposal.server.map { "Connect \($0.label)" } ?? "Change settings", systemImage: "gearshape")
                .font(.headline)
            Text(scope).font(.caption).foregroundStyle(.secondary)
            if proposal.status == .waiting {
                Text(proposal.reason).font(.callout)
                ForEach(proposal.changes) { change in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(SettingsRegistry[change.id]?.title ?? change.id).font(.callout.weight(.medium))
                            let detail = "\(preview(change.before)) → \(preview(change.after))"
                            if detail.count > 240 || detail.contains("\n") {
                                ScrollView { Text(detail).frame(maxWidth: .infinity, alignment: .leading) }
                                    .frame(maxHeight: 110)
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            } else {
                                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 6)
                        if proposal.changes.count > 1 {
                            Button("Apply This") { requestApply(item: change.id) }
                        }
                    }
                }
                if let draft = proposal.server {
                    Text(draft.url ?? ([draft.command ?? ""] + draft.arguments).joined(separator: " "))
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                HStack {
                    if proposal.server != nil {
                        Button("Review Connection…") { showServer = true }.buttonStyle(.borderedProminent)
                    } else {
                        Button(proposal.changes.count > 1 ? "Apply All" : "Apply") { requestApply(item: nil) }
                            .buttonStyle(.borderedProminent)
                        if let id = proposal.changes.first?.id, let definition = SettingsRegistry[id] {
                            Button("Edit in Settings") {
                                model.editingSettingsProposal = proposal
                                model.openSetting(definition, source: proposal.source)
                            }
                        }
                    }
                    Button("Reject") { act { try model.rejectSettingsProposal(proposal.id) } }
                }
                .disabled(deciding)
            }
            if proposal.status == .installed {
                Button("Finish Connection Setup…") { showServer = true }.buttonStyle(.borderedProminent)
            }
            if !proposal.appliedChanges.isEmpty {
                HStack {
                    Label("Settings applied", systemImage: "checkmark.circle").font(.caption)
                    Button("Undo") { act { try model.undoSettingsProposal(proposal.id) } }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.proposal.\(proposal.id)")
        .confirmationDialog("Apply these settings changes?", isPresented: $confirm) {
            Button("Apply Changes") { act { try model.applySettingsProposal(proposal.id, item: singleItem) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This affects \(scope.lowercased()). Review the proposed value and its consequences before applying.")
        }
        .sheet(isPresented: $showServer) {
            if let draft = proposal.server {
                SettingsMCPReview(draft: draft, proposal: proposal).environment(model)
            }
        }
    }

    private var scope: String {
        let allChanges = proposal.changes + proposal.appliedChanges
        let hasProject = proposal.server.map { !$0.global } ?? allChanges.contains { SettingsRegistry[$0.id]?.scope == .project }
        let hasProfile = proposal.server?.global == true || allChanges.contains { SettingsRegistry[$0.id]?.scope == .profile }
        if hasProject, let id = proposal.source.projectID,
           let title = model.workspaceProjects.first(where: { $0.id == id })?.title {
            return hasProfile ? "Aitvaras profile and \(title)" : "Project · \(title)"
        }
        return "Aitvaras profile"
    }

    private func preview(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text.isEmpty ? "Empty" : text }
        if let flag = value.boolValue { return flag ? "On" : "Off" }
        return value.jsonString
    }

    private func requestApply(item: String?) {
        singleItem = item
        if proposal.isSensitive { confirm = true }
        else { act { try model.applySettingsProposal(proposal.id, item: item) } }
    }

    private func act(_ action: () throws -> Void) {
        deciding = true
        defer { deciding = false }
        do { try action(); error = nil }
        catch { self.error = (error as? SettingsToolError)?.localizedDescription ?? "Could not save these settings." }
    }
}

private struct SettingsMCPReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: SettingsMCPDraft
    let proposal: SettingsProposal
    @State private var secrets: [String: String] = [:]
    @State private var accountID: UUID?
    @State private var applied = false
    @State private var tools: [MCPGatewayTool]?
    @State private var nativeTools: [String]?
    @State private var testing = false
    @State private var error: String?
    @State private var globalConfirmed = false
    @State private var narrowToProject = false

    init(draft: SettingsMCPDraft, proposal: SettingsProposal) {
        self.draft = draft
        self.proposal = proposal
        _accountID = State(initialValue: proposal.serverAccountID)
        _applied = State(initialValue: proposal.status == .installed)
    }

    private var requiredSecrets: [String] { draft.secretEnvironment + draft.secretHeaders }
    private var scopeTitle: String {
        if draft.global && !narrowToProject { return "All projects" }
        return model.workspaceProjects.first { $0.id == proposal.source.projectID }?.title ?? "Current project"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(draft.label, systemImage: "point.3.connected.trianglepath.dotted").font(.title2.weight(.semibold))
            Form {
                Section("Connection") {
                    LabeledContent("Scope", value: scopeTitle)
                    LabeledContent("Name", value: draft.name)
                    if let url = draft.url { LabeledContent("Endpoint", value: url).textSelection(.enabled) }
                    if let command = draft.command {
                        LabeledContent("Command", value: command).textSelection(.enabled)
                        ForEach(draft.arguments.indices, id: \.self) { index in
                            LabeledContent("Argument \(index + 1)", value: draft.arguments[index]).textSelection(.enabled)
                        }
                    }
                    ForEach(draft.environment.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: draft.environment[key] ?? "").textSelection(.enabled)
                    }
                    ForEach(draft.headers.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: draft.headers[key] ?? "").textSelection(.enabled)
                    }
                    if draft.global, !applied {
                        if proposal.source.projectID != nil {
                            Toggle("Use only in this project", isOn: $narrowToProject)
                        }
                        if !narrowToProject {
                            Toggle("I want this connection available to every project", isOn: $globalConfirmed)
                        }
                    }
                    if draft.transport == .stdio {
                        Text("This runs a local program when an agent starts with the approved configuration.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !applied, !requiredSecrets.isEmpty {
                    Section("Credentials") {
                        ForEach(requiredSecrets, id: \.self) { key in
                            SecureField(key, text: Binding(get: { secrets[key, default: ""] }, set: { secrets[key] = $0 }))
                        }
                        Text("Values are stored in your Keychain.").foregroundStyle(.secondary)
                    }
                }
                if applied {
                    Section("Connection test") {
                        if let tools {
                            Text("Connected · \(tools.count) tools")
                            ForEach(tools, id: \.revision) { tool in
                                LabeledContent(tool.definition.name, value: tool.annotations.readOnly == true ? "Suggested · Read" : "Suggested · Ask")
                            }
                        } else if let accountID {
                            if draft.auth == .oauth {
                                Button(model.gatewaySigningIn == accountID ? "Signing in…" : "Sign In") { model.startGatewaySignIn(accountID) }
                                    .disabled(model.gatewaySigningIn != nil)
                            }
                            Button(testing ? "Testing…" : "Test Connection") { test(accountID) }
                                .disabled(testing || model.gatewaySigningIn != nil)
                            if let message = model.gatewaySignInError { Text(message).foregroundStyle(.red) }
                        } else if let nativeTools {
                            Text("Connected · \(nativeTools.count) tools")
                            ForEach(nativeTools, id: \.self) { Text($0) }
                            Text("The provider loads this definition for its next session. Its own tool approval policy applies.")
                                .foregroundStyle(.secondary)
                        } else {
                            Button(testing ? "Testing…" : "Test Connection") { testNative(proposal.server ?? draft) }
                                .disabled(testing)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
            HStack {
                Button(applied ? "Done" : "Cancel") {
                    if applied { try? model.completeMCPProposal(proposal.id) }
                    dismiss()
                }
                Spacer()
                if !applied {
                    Button("Apply Connection") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(testing || (draft.global && !narrowToProject && !globalConfirmed) || requiredSecrets.contains { secrets[$0, default: ""].isEmpty })
                } else if let projectID = proposal.source.projectID {
                    Button("Review Tool Approvals") {
                        try? model.completeMCPProposal(proposal.id)
                        dismiss()
                        SettingsNavigation.open(.project(projectID, section: .servers))
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 530, height: 570)
        .task(id: model.gatewaySigningIn) {
            guard applied, let accountID, model.gatewaySigningIn == nil, draft.auth == .oauth, tools == nil,
                  (try? await model.gatewayAccountSignedIn(accountID)) == true, !Task.isCancelled else { return }
            test(accountID)
        }
    }

    private func apply() {
        testing = true
        error = nil
        Task {
            defer { testing = false }
            do {
                guard let stores = model.stores else { throw SettingsToolError.unavailable }
                try model.recordSettingsApproval(.suggestionAccepted, "Approved an MCP connection", proposal: proposal, stores: stores)
                var reviewed = draft
                if narrowToProject { reviewed.global = false }
                accountID = try await model.installSettingsMCPDraft(reviewed, projectID: proposal.source.projectID, secrets: secrets)
                secrets = [:]
                applied = true
                try model.markMCPProposalInstalled(proposal.id, draft: reviewed, accountID: accountID)
                if let accountID {
                    if draft.auth == .oauth { model.startGatewaySignIn(accountID) }
                    else { test(accountID) }
                } else { testNative(reviewed) }
            } catch {
                self.error = "Could not save the connection. Check the name, endpoint and credentials."
            }
        }
    }

    private func testNative(_ reviewed: SettingsMCPDraft) {
        testing = true
        error = nil
        Task {
            defer { testing = false }
            do { nativeTools = try await model.testNativeSettingsMCP(reviewed, projectID: proposal.source.projectID) }
            catch { self.error = "Could not list the tools. Check the connection definition in Settings." }
        }
    }

    private func test(_ accountID: UUID) {
        testing = true
        error = nil
        Task {
            defer { testing = false }
            do { tools = try await model.testSettingsGatewayAccount(accountID) }
            catch { self.error = "Could not list tools. Check the endpoint or complete sign-in first." }
        }
    }
}


struct SettingsProposalValueEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let proposal: SettingsProposal
    @State private var input: [String: String]
    @State private var error: String?

    init(proposal: SettingsProposal) {
        self.proposal = proposal
        _input = State(initialValue: Dictionary(uniqueKeysWithValues: proposal.changes.map {
            ($0.id, $0.after.stringValue ?? $0.after.jsonString)
        }))
    }

    var body: some View {
        Form {
            Section("Review proposed values") {
                ForEach(proposal.changes) { change in
                    if let setting = SettingsRegistry[change.id] {
                        let value = Binding(get: { input[change.id, default: ""] }, set: { input[change.id] = $0 })
                        switch setting.valueType {
                        case .choice(let options):
                            Picker(setting.title, selection: value) { ForEach(options, id: \.self) { Text($0).tag($0) } }
                        case .boolean:
                            Toggle(setting.title, isOn: Binding(get: { value.wrappedValue == "true" },
                                set: { value.wrappedValue = $0 ? "true" : "false" }))
                        default:
                            TextField(setting.title, text: value, axis: .vertical)
                        }
                        if let hint = setting.hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save Proposal Edits") { save() }.buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 260)
    }

    private func save() {
        do {
            let values = try proposal.changes.map { change -> (String, JSONValue) in
                guard let setting = SettingsRegistry[change.id], let text = input[change.id] else {
                    throw SettingsToolError.invalidValue
                }
                switch setting.valueType {
                case .choice, .text: return (change.id, .string(text))
                default:
                    guard let value = JSONValue.parse(text) else { throw SettingsToolError.invalidValue }
                    return (change.id, value)
                }
            }
            try model.editSettingsProposal(proposal.id, values: Dictionary(uniqueKeysWithValues: values))
            dismiss()
        } catch { self.error = "Check the proposed values. This edit has not changed any settings." }
    }
}
