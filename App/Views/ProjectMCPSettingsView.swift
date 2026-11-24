import SwiftUI
import AitvarasAgent
import AitvarasAgents
import AitvarasCore
import AitvarasStore

/// The same connection editor serves the project and global Settings destinations.
struct ProjectMCPSettingsView: View {
    let projectID: UUID?
    var directory: URL? = nil
    var handlesGatewayTokenLinks = true

    @Environment(AppModel.self) private var model
    @State private var accounts: [GatewayUpstreamAccount] = []
    @State private var authenticated: [UUID: Bool] = [:]
    @State private var selectedAccounts: [String: UUID] = [:]
    @State private var disabledGlobals: Set<String> = []
    @State private var approvals: [UUID: GatewayProjectApprovalSettings] = [:]
    @State private var catalog: [UUID: [MCPGatewayTool]] = [:]
    @State private var testing: Set<UUID> = []
    @State private var errors: [UUID: String] = [:]
    @State private var loadError: String?
    @State private var adding = false
    @State private var showsHelp = false
    @State private var editorRevision = UUID()
    @State private var tokenEditor: GatewayUpstreamAccount?
    @State private var confirmingFullAuto: GatewayUpstreamAccount?
    @State private var removingAccount: GatewayUpstreamAccount?
    @State private var reloadGeneration = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if projectID == nil { Text("MCP servers").font(.headline) }
                Button { showsHelp.toggle() } label: {
                    Image(systemName: showsHelp ? "info.circle.fill" : "info.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About MCP servers")
                .help("About MCP servers")
                Spacer()
                if !adding {
                    Button("Add server", systemImage: "plus") { adding = true }
                        .accessibilityIdentifier("settings.mcp.add")
                }
            }
            if showsHelp {
                Text("MCP servers give agents tools from other apps. Managed HTTPS servers use the Aitvaras gateway. Provider-managed servers connect through the agent’s CLI and use that provider’s approval controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if adding {
                MCPSettingsServerForm(projectID: projectID, directory: directory, onCancel: { adding = false }) { id, auth in
                    adding = false
                    editorRevision = UUID()
                    if let id, auth == .oauth { model.startGatewaySignIn(id) }
                    Task { await reload() }
                }
            }
            if let loadError { notice(loadError) }
            let names = Set(accounts.map(\.serverName)).sorted()
            if !names.isEmpty {
                Divider()
                Text("Gateway connections").font(.headline).settingsAnchor("project.mcpApprovals")
                ForEach(names, id: \.self) { name in
                    serverGroup(name, accounts: accounts.filter { $0.serverName == name })
                }
            }
            Divider()
            AgentSetupSection(projectID: projectID, directory: directory, showsServerDefinitions: true, serversOnly: true)
                .id(editorRevision)
        }
        .accessibilityIdentifier("settings.mcp.servers")
        .task(id: projectID) { await reload() }
        .onChange(of: model.gatewaySigningIn) { _, account in
            if account == nil { Task { await reload() } }
        }
        .onChange(of: model.gatewayTokenAccountToEdit, initial: true) { _, id in
            guard handlesGatewayTokenLinks, let id,
                  let account = try? model.stores?.gatewayUpstream(id: id).account,
                  account.authKind == .staticHeader, account.definitionProjectID == projectID else { return }
            model.gatewayTokenAccountToEdit = nil
            tokenEditor = account
        }
        .sheet(item: $tokenEditor, onDismiss: { Task { await reload() } }) { account in
            MCPSettingsTokenEditor(account: account)
        }
        .confirmationDialog("Use full automatic approval?",
                            isPresented: Binding(get: { confirmingFullAuto != nil }, set: { if !$0 { confirmingFullAuto = nil } }),
                            presenting: confirmingFullAuto) { account in
            Button("Enable Full auto", role: .destructive) { setMode(.fullAuto, for: account) }
        } message: { account in
            Text("Eligible tools from \(account.displayName) can read and change data without asking. Protected actions still require review.")
        }
        .confirmationDialog("Remove gateway account?",
                            isPresented: Binding(get: { removingAccount != nil }, set: { if !$0 { removingAccount = nil } }),
                            presenting: removingAccount) { account in
            Button("Remove account", role: .destructive) { Task { await removeAccount(account) } }
        } message: { account in
            Text("This removes the credential and connection for \(account.displayName).")
        }
    }

    private func serverGroup(_ name: String, accounts options: [GatewayUpstreamAccount]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let projectID { routing(name, options: options, projectID: projectID) }
            ForEach(options) { account in
                accountCard(account)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.mcp.server.\(name)")
    }

    private func routing(_ name: String, options: [GatewayUpstreamAccount], projectID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name).font(.subheadline.weight(.semibold))
            if options.contains(where: \.globallyAvailable) {
                Toggle("Allow shared accounts in this project", isOn: Binding(
                    get: { !disabledGlobals.contains(name) },
                    set: { enabled in
                        update(accountID: nil) { stores in
                            try stores.editAgentSetup(projectID: projectID, edit: .globalEnabled(name: name, enabled: enabled))
                        }
                    }))
            }
            Picker("Account for this project", selection: Binding(
                get: { selectedAccounts[name] },
                set: { accountID in
                    update(accountID: nil) { stores in
                        try stores.selectGatewayUpstreamAccount(projectID: projectID, serverName: name, accountID: accountID)
                    }
                })) {
                Text("Use shared default if available").tag(nil as UUID?)
                ForEach(options) { option in
                    Text(option.displayName).tag(Optional(option.id))
                        .disabled(option.globallyAvailable && disabledGlobals.contains(name))
                }
            }
            .accessibilityIdentifier("settings.mcp.account.\(name)")
        }
        .padding(.top, 5)
    }

    private func accountCard(_ account: GatewayUpstreamAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(account.displayName, systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.callout.weight(.medium))
                    Text([account.authKind == .oauth ? "OAuth" : "Fixed token",
                          account.globallyAvailable ? "Shared" : "This project",
                          credentialStatus(account)].joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if account.definitionProjectID == projectID { credentialActions(account) }
            }
            if account.definitionProjectID == projectID {
                Toggle("Trust server tool hints", isOn: Binding(get: { account.trusted }, set: { value in
                    catalog[account.id] = nil
                    update(accountID: account.id) { try $0.setGatewayUpstreamTrust(id: account.id, trusted: value) }
                }))
                .help("Trusted hints can help classify reads in this server’s approval mode.")
                if projectID == nil && account.globallyAvailable {
                    Toggle("Shared default", isOn: Binding(get: { account.isGlobalDefault }, set: { value in
                        update(accountID: account.id) {
                            try $0.setGatewayGlobalDefault(serverName: account.serverName, accountID: value ? account.id : nil)
                        }
                    }))
                    .help("Projects can choose an account or turn off shared accounts.")
                }
            } else if account.globallyAvailable {
                Button("Shared account settings", systemImage: "arrow.up.right") {
                    SettingsNavigation.open(.page(.connections), settingID: "connections.servers")
                }.buttonStyle(.link)
            }
            if let projectID, let rules = approvals[account.id] {
                approvalEditor(account, rules: rules, projectID: projectID)
            }
            HStack {
                Button("Test connection", systemImage: "checkmark.circle") { test(account) }
                    .disabled(testing.contains(account.id))
                    .accessibilityIdentifier("settings.mcp.test.\(account.serverName)")
                if testing.contains(account.id) { ProgressView().controlSize(.small) }
                if let tools = catalog[account.id] {
                    Text("\(tools.count) tools found").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if account.definitionProjectID == projectID {
                    Button("Remove", role: .destructive) { removingAccount = account }.buttonStyle(.borderless)
                }
            }
            if let error = errors[account.id] { notice(error) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private func credentialActions(_ account: GatewayUpstreamAccount) -> some View {
        if account.authKind == .staticHeader {
            Button(authenticated[account.id] == true ? "Replace token" : "Set token") { tokenEditor = account }
            if authenticated[account.id] == true {
                Button("Remove token") { Task { await signOut(account) } }
            }
        } else if model.gatewaySigningIn == account.id {
            Button("Cancel sign-in") { model.cancelGatewaySignIn() }
        } else if authenticated[account.id] == true {
            Button("Sign out") { Task { await signOut(account) } }
        } else {
            Button("Sign in") { model.startGatewaySignIn(account.id) }
                .disabled(model.gatewaySigningIn != nil)
        }
    }

    private func credentialStatus(_ account: GatewayUpstreamAccount) -> String {
        if model.gatewaySigningIn == account.id { return "Signing in…" }
        if account.authKind == .staticHeader {
            if model.gatewaySignInRequests.contains(where: { $0.id == account.id && $0.tokenRejected }) { return "Token rejected" }
            return authenticated[account.id] == true ? "Token stored" : "Token required"
        }
        return authenticated[account.id] == true ? "Signed in" : "Signed out"
    }

    private func approvalEditor(_ account: GatewayUpstreamAccount, rules: GatewayProjectApprovalSettings,
                                projectID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Approvals in this project", selection: Binding(get: { rules.mode }, set: { mode in
                guard let mode else { return }
                if mode == .fullAuto { confirmingFullAuto = account }
                else { setMode(mode, for: account) }
            })) {
                if rules.mode == nil { Text("Inherit existing policy").tag(nil as GatewayServerApprovalMode?) }
                ForEach(GatewayServerApprovalMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(Optional(mode))
                }
            }
            .help("The current chat can require stricter approvals. A protected action always follows its safety rule.")
            .accessibilityIdentifier("settings.mcp.approvalMode.\(account.serverName)")

            if let tools = catalog[account.id], !tools.isEmpty {
                Text("Tool classification").font(.subheadline.weight(.semibold))
                ForEach(tools, id: \.revision) { tool in classification(tool, rules: rules, projectID: projectID) }
            }

            if !rules.toolOverrides.isEmpty || !rules.toolGrants.isEmpty {
                HStack {
                    Text("Saved tool rules").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Remove all rules", role: .destructive) {
                        update(accountID: account.id) {
                            try $0.clearGatewayServerApprovalRules(projectID: projectID, accountID: account.id,
                                legacyToolRevisions: Set((catalog[account.id] ?? []).map(\.revision)))
                        }
                    }.buttonStyle(.borderless)
                }
                ForEach(rules.toolGrants) { grant in
                    ruleRow(grant.toolName ?? "Tool approval", detail: "Always allow") {
                        update(accountID: account.id) { try $0.revokeGatewayToolGrant(projectID: projectID, toolRevision: grant.toolRevision) }
                    }
                }
                ForEach(rules.toolOverrides) { rule in
                    ruleRow(rule.toolName, detail: riskLabel(rule.risk)) {
                        update(accountID: account.id) { try $0.revokeGatewayToolOverride(projectID: projectID, toolRevision: rule.toolRevision) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func classification(_ tool: MCPGatewayTool, rules: GatewayProjectApprovalSettings,
                                              projectID: UUID) -> some View {
        if GatewayUpstreamToolSafety.isForbidden(tool) || GatewayUpstreamToolSafety.confirmationReason(tool) != nil {
            LabeledContent(tool.definition.name,
                           value: GatewayUpstreamToolSafety.isForbidden(tool) ? "Blocked" : "Always asks")
        } else {
            Picker(tool.definition.name, selection: Binding(
                get: { rules.toolOverrides.first { $0.toolRevision == tool.revision }?.risk },
                set: { risk in
                    let accountID: UUID?
                    if case .upstream(_, let id, _) = tool.origin { accountID = id } else { accountID = nil }
                    update(accountID: accountID) { try $0.setGatewayToolApprovalOverride(projectID: projectID, tool: tool, risk: risk) }
                })) {
                Text(tool.annotations.readOnly == true ? "Suggested read" : "Use server policy").tag(nil as ActionRisk?)
                ForEach([ActionRisk.read, .reversibleWrite, .confirmable], id: \.self) { risk in
                    Text(riskLabel(risk)).tag(Optional(risk))
                }
            }
        }
    }

    private func ruleRow(_ name: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", action: action)
                .help("Remove this rule")
        }.font(.caption)
    }

    private func riskLabel(_ risk: ActionRisk) -> String {
        switch risk {
        case .read: "Read"
        case .reversibleWrite: "Write"
        case .confirmable: "Ask"
        }
    }

    private func setMode(_ mode: GatewayServerApprovalMode, for account: GatewayUpstreamAccount) {
        guard let projectID else { return }
        update(accountID: account.id) { try $0.setGatewayServerApprovalMode(projectID: projectID, accountID: account.id, mode: mode) }
    }

    private func test(_ account: GatewayUpstreamAccount) {
        guard testing.insert(account.id).inserted else { return }
        errors[account.id] = nil
        Task {
            defer { testing.remove(account.id) }
            do {
                let tools = try await model.testSettingsGatewayAccount(account.id)
                if let projectID, let stores = model.stores {
                    try stores.expireChangedGatewayToolRules(projectID: projectID, tools: tools)
                }
                catalog[account.id] = tools
                await reload()
            } catch { errors[account.id] = "The connection test failed. Check the credential and endpoint." }
        }
    }

    private func reload() async {
        guard let stores = model.stores else { return }
        let generation = UUID()
        reloadGeneration = generation
        do {
            let current = try stores.allGatewayUpstreamAccounts().filter {
                $0.definitionProjectID == nil || $0.definitionProjectID == projectID
            }
            accounts = current
            if let projectID {
                let selection = try stores.gatewayProjectAssignments(projectID: projectID)
                selectedAccounts = selection.selected
                disabledGlobals = selection.disabled
                for account in current {
                    approvals[account.id] = try? stores.gatewayProjectApprovalSettings(projectID: projectID, accountID: account.id,
                        legacyToolRevisions: Set((catalog[account.id] ?? []).map(\.revision)))
                }
            }
            var credentials: [UUID: Bool] = [:]
            for account in current {
                credentials[account.id] = try? await model.gatewayAccountSignedIn(account.id)
                guard reloadGeneration == generation, !Task.isCancelled else { return }
            }
            authenticated = credentials
        } catch { loadError = "Could not load MCP connections." }
    }

    private func update(accountID: UUID?, _ operation: (Stores) throws -> Void) {
        guard let stores = model.stores else { return }
        do {
            try operation(stores)
            if let accountID { errors[accountID] = nil } else { loadError = nil }
            Task { await model.refreshGatewayRouting(); await reload() }
        } catch let error as GatewayUpstreamError {
            if let accountID { errors[accountID] = error.errorDescription } else { loadError = error.errorDescription }
        } catch {
            setError("Could not save the approval or routing setting.", for: accountID)
        }
    }

    private func setError(_ text: String, for accountID: UUID?) {
        if let accountID { errors[accountID] = text } else { loadError = text }
    }

    private func signOut(_ account: GatewayUpstreamAccount) async {
        do {
            try await model.signOutGatewayAccount(account.id)
            catalog[account.id] = nil
            errors[account.id] = nil
            await reload()
        } catch { errors[account.id] = "Could not remove the credential." }
    }

    private func removeAccount(_ account: GatewayUpstreamAccount) async {
        guard let stores = model.stores else { return }
        do {
            let projects = try stores.workspaceProjects(includeHidden: true)
            for project in projects {
                let assignments = try stores.gatewayProjectAssignments(projectID: project.id)
                if assignments.selected.values.contains(account.id) { throw GatewayUpstreamError.accountInUse }
            }
            try await model.signOutGatewayAccount(account.id)
            try stores.removeGatewayUpstreamAccount(id: account.id)
            await model.refreshGatewayRouting()
            await reload()
        } catch let error as GatewayUpstreamError { errors[account.id] = error.errorDescription }
        catch { errors[account.id] = "Could not remove the gateway account." }
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.caption).foregroundStyle(.orange)
    }
}

private struct MCPSettingsTokenEditor: View {
    let account: GatewayUpstreamAccount

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var tokenFocused: Bool
    @State private var token = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set token for \(account.displayName)").font(.headline)
            SecureField("New token", text: $token)
                .focused($tokenFocused)
                .disabled(saving)
                .accessibilityIdentifier("gateway.fixed-token.replacement")
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save token", action: save).disabled(token.isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled(saving)
        .onAppear { tokenFocused = true }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.replaceGatewayToken(account.id, token: token)
                token = ""
                dismiss()
            } catch let failure as GatewayUpstreamError { error = failure.errorDescription }
            catch { self.error = "Could not save the token. Check Keychain access." }
        }
    }
}

private struct MCPSettingsServerForm: View {
    private enum Transport: String, CaseIterable {
        case https = "HTTPS", stdio = "Local command", nativeHTTP = "Provider HTTP", nativeSSE = "Provider SSE"

        var isLegacy: Bool { self == .nativeHTTP || self == .nativeSSE }
    }

    let projectID: UUID?
    let directory: URL?
    let onCancel: () -> Void
    let onSaved: (UUID?, SettingsMCPDraft.Authentication) -> Void

    @Environment(AppModel.self) private var model
    @State private var transport = Transport.https
    @State private var auth = SettingsMCPDraft.Authentication.oauth
    @State private var name = ""
    @State private var label = ""
    @State private var endpoint = ""
    @State private var command = ""
    @State private var arguments = ""
    @State private var fields: [AgentMCPFieldDraft] = []
    @State private var headerName = ""
    @State private var token = ""
    @State private var global = false
    @State private var saving = false
    @State private var error: String?

    private var isGlobal: Bool { projectID == nil || global }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validName: Bool {
        if transport.isLegacy { return (try? AgentMCPConfiguration.validateName(cleanName)) != nil }
        return cleanName.range(of: #"^[a-z][a-z0-9_]{0,63}$"#, options: .regularExpression) != nil
    }
    private var validAddress: Bool {
        guard let url = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host?.isEmpty == false, url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return transport.isLegacy ? ["http", "https"].contains(url.scheme) : url.scheme == "https" && url.query == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Add MCP server").font(.subheadline.weight(.semibold))
            Picker("Connection type", selection: $transport) {
                ForEach(Transport.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: transport) {
                auth = transport == .https ? .oauth : .none
                fields.removeAll()
                error = nil
            }
            TextField("Server name", text: $name).accessibilityIdentifier("settings.mcp.new.name")
            if !transport.isLegacy {
                Text("Start with a lowercase letter. Use lowercase letters, digits, or underscores.")
                    .font(.caption).foregroundStyle(!name.isEmpty && !validName ? Color.orange : Color.secondary)
                TextField("Display name (optional)", text: $label)
            }
            if transport == .stdio {
                TextField("Command", text: $command).accessibilityIdentifier("settings.mcp.new.command")
                TextField("Arguments, one per line", text: $arguments, axis: .vertical)
                    .lineLimit(1...4)
            } else {
                TextField(transport.isLegacy ? "Server URL" : "HTTPS endpoint", text: $endpoint)
                    .accessibilityIdentifier("settings.mcp.new.endpoint")
                if !endpoint.isEmpty && !validAddress {
                    Text(transport.isLegacy ? "Enter a valid HTTP or HTTPS URL." : "Enter an HTTPS URL without credentials or a query.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if transport == .https {
                Picker("Authentication", selection: $auth) {
                    Text("OAuth").tag(SettingsMCPDraft.Authentication.oauth)
                    Text("Fixed token").tag(SettingsMCPDraft.Authentication.header)
                    Text("None").tag(SettingsMCPDraft.Authentication.none)
                }
                if auth == .header {
                    TextField("Header name (optional)", text: $headerName)
                        .help("Leave blank to use an Authorization bearer token.")
                    SecureField("Token", text: $token).accessibilityIdentifier("settings.mcp.new.token")
                }
            }
            if transport != .https || auth == .none { extraFields }
            if projectID != nil {
                Toggle("Make available to other projects", isOn: $global)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("settings.mcp.new.error")
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isGlobal ? "Add shared server" : "Add to project", action: save)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.mcp.new.save")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .disabled(saving)
    }

    private var extraFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($fields) { $field in
                HStack {
                    TextField("Field name", text: $field.name)
                    if field.secret { SecureField("Value", text: $field.value) }
                    else { TextField("Value", text: $field.value) }
                    Toggle("Secret", isOn: $field.secret).toggleStyle(.checkbox)
                    Button {
                        fields.removeAll { $0.id == field.id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).accessibilityLabel("Remove field")
                }
            }
            Button(transport == .stdio ? "Add environment variable" : "Add request header", systemImage: "plus") {
                fields.append(.init())
            }.buttonStyle(.borderless)
        }
    }

    private func save() {
        error = nil
        guard validName else {
            error = "Choose a valid server name."
            return
        }
        guard transport == .stdio ? !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : validAddress else {
            error = transport == .stdio ? "Enter a command." : "Enter a valid endpoint."
            return
        }
        guard auth != .header || transport != .https || !token.isEmpty else {
            error = "Enter a token."
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                let id = try await saveDefinition()
                token = ""; fields.removeAll()
                onSaved(id, transport == .https ? auth : .none)
            } catch let failure as GatewayUpstreamError { error = failure.errorDescription }
            catch AgentMCPError.nameCollision { error = "A server already uses this name. Choose another name." }
            catch AgentMCPError.invalidName { error = "The name is unavailable. Choose another name." }
            catch { self.error = "Could not add the server. Check the address, fields, and credential." }
        }
    }

    private func saveDefinition() async throws -> UUID? {
        let cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if transport.isLegacy {
            guard let coordinator = model.agentSetupCoordinator else { throw SettingsToolError.unavailable }
            var draft = AgentMCPServerDraft()
            draft.name = cleanName
            draft.transport = transport == .nativeSSE ? .sse : .http
            draft.url = cleanEndpoint
            draft.fields = fields
            try await coordinator.saveServer(projectID: isGlobal ? nil : projectID, directory: directory, draft: draft)
            model.chatModel?.invalidateCommandCatalog()
            return nil
        }
        let effectiveAuth = transport == .https ? auth : .none
        var draft = SettingsMCPDraft(name: cleanName, label: label.isEmpty ? cleanName : label,
            transport: transport == .stdio ? .stdio : .https, auth: effectiveAuth, global: isGlobal)
        var secrets: [String: String] = [:]
        if transport == .stdio {
            draft.command = command
            draft.arguments = arguments.isEmpty ? [] : arguments.components(separatedBy: "\n")
        } else { draft.url = cleanEndpoint }
        if effectiveAuth == .header {
            let custom = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = custom.isEmpty ? "Authorization" : custom
            draft.secretHeaders = [key]
            secrets[key] = token
        } else if effectiveAuth == .none {
            for field in fields {
                let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw SettingsToolError.invalidDraft }
                if field.secret {
                    guard secrets.updateValue(field.value, forKey: name) == nil else { throw SettingsToolError.invalidDraft }
                    if transport == .stdio { draft.secretEnvironment.append(name) }
                    else { draft.secretHeaders.append(name) }
                } else if transport == .stdio {
                    guard draft.environment.updateValue(field.value, forKey: name) == nil else { throw SettingsToolError.invalidDraft }
                } else {
                    guard draft.headers.updateValue(field.value, forKey: name) == nil else { throw SettingsToolError.invalidDraft }
                }
            }
        }
        let id = try await model.installSettingsMCPDraft(draft, projectID: projectID, secrets: secrets)
        model.chatModel?.invalidateCommandCatalog()
        return id
    }
}
