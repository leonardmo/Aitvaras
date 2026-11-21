import SwiftUI
import AitvarasCore
import AitvarasAgent
import AitvarasAgents
import AitvarasConnectors
import AitvarasStore

/// Connections: unconfigured by default, everything added through one
/// "Add Connection" flow (user decision 2026-07-06). Custom APIs are
/// first-class — paste a manifest, or let Claude draft one from docs.
struct ConnectorsView: View {
    var handlesGatewayTokenLinks = false
    @Environment(AppModel.self) private var model
    @State private var showCatalog = false
    @State private var configuringKind: ConnectionKind?
    @State private var refresh = 0
    @State private var connectorHealth: [String: ConnectorHealth] = [:]
    @State private var showMessageSafety = false
    @State private var pendingSenderCount = 0

    var body: some View {
        List {
            Section {
                Text("Read tools run freely; writes ask for confirmation unless whitelisted. Secrets live only in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Always available") {
                builtInRow(name: "Calendar & Reminders", icon: "calendar",
                           detail: "Creates into your 'Aitvaras' calendar/list",
                           connectorIDs: ["calendar", "reminders"])
                builtInRow(name: "Apple Mail", icon: "envelope",
                           detail: "Read + search only — sending is not built in",
                           connectorIDs: ["mail"])
                builtInRow(name: "Web search", icon: "globe",
                           detail: "DuckDuckGo search + page reading",
                           connectorIDs: ["web"])
                builtInRow(name: "Daily goals", icon: "target",
                           detail: "Plan the day together in chat or voice",
                           connectorIDs: ["goals"])
                builtInRow(name: "Knowledge (RAG)", icon: "books.vertical",
                           detail: "Your indexed folders, see Knowledge tab",
                           connectorIDs: ["memory"])
                builtInRow(name: "CLI delegation", icon: "terminal",
                           detail: CloudAgentSettings.selection(for: .delegation) == .local
                               ? "Disabled under Models → Cloud agents"
                               : DelegateConnector.findAgent() != nil
                                   ? "Uses the provider selected under Models; heavy tasks always ask first"
                                   : "Install Claude Code or Codex CLI, then sign in once",
                           connectorIDs: ["delegate"])
            }

            ForgeConnectionsSection()

            GatewayConnectionsSection(handlesGatewayTokenLinks: handlesGatewayTokenLinks)

            Section("Connections") {
                let active = activeConnections
                if active.isEmpty {
                    Text("Nothing connected yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(active) { connection in
                    HStack {
                        Image(systemName: connection.kind.icon)
                            .frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(connection.title)
                            Text(connection.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let message = statusMessage(for: connectorHealth[connection.id]) {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(statusColor(for: connectorHealth[connection.id]))
                            }
                        }
                        Spacer()
                        statusIndicator(connectorHealth[connection.id])
                        Button("Remove", role: .destructive) {
                            remove(connection)
                        }
                        .controlSize(.small)
                    }
                }
                Button {
                    showCatalog = true
                } label: {
                    Label("Add Connection…", systemImage: "plus.circle.fill")
                }
            }

            if let warnings = model.integrations?.customManifestWarnings,
               !warnings.isEmpty {
                Section("Custom connector warnings") {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let warnings = model.integrations?.connectionRestoreWarnings,
               !warnings.isEmpty {
                Section("Connection warnings") {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let warning = model.integrations?.phoneDeliveryWarning {
                Section("Phone delivery") {
                    Label(warning, systemImage: "paperplane.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Message safety") {
                Button {
                    showMessageSafety = true
                } label: {
                    HStack {
                        Label("Trusted senders", systemImage: "person.badge.shield.checkmark")
                        Spacer()
                        if pendingSenderCount > 0 {
                            Text("\(pendingSenderCount) to review")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                Text("Unknown mail and notification senders are held without model access. Trust only permits quarantined triage; it never makes message text an instruction or removes action confirmations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Autonomy whitelist") {
                WhitelistEditor()
            }
            Section("MCP servers (all projects)") {
                AgentSetupSection(projectID: nil)
            }
        }
        .id(refresh)
        .navigationTitle("Connections")
        .toolbar {
            Button("Check connections", systemImage: "arrow.clockwise") {
                Task {
                    let id = model.activityReporter?.begin(ActivityRun(category: .connection,
                        title: "Check connections", stage: "Checking configured service access",
                        executionLocation: "This Mac", dataAccess: "Connection health checks",
                        dataDestination: "Configured services; may request local permissions"))
                    await refreshConnectorHealth()
                    if let id { model.activityReporter?.finish(id: id, state: .succeeded, outcome: "Checks finished; individual results are shown below") }
                }
            }
        }
        .sheet(isPresented: $showCatalog) {
            CatalogSheet { kind in
                showCatalog = false
                configuringKind = kind
            }
        }
        .sheet(item: $configuringKind) { kind in
            ConnectionSetupSheet(kind: kind) {
                configuringKind = nil
                refresh += 1
            }
            .environment(model)
        }
        .sheet(isPresented: $showMessageSafety, onDismiss: {
            refreshMessageSafetyCount()
        }) {
            MessageSafetySheet()
                .environment(model)
        }
        .task(id: refresh) {
            // Opening Settings never starts network checks or permission prompts.
            refreshMessageSafetyCount()
        }
    }

    private func builtInRow(
        name: String, icon: String, detail: String, connectorIDs: [String]
    ) -> some View {
        let health = combinedHealth(for: connectorIDs)
        return HStack {
            Image(systemName: icon).frame(width: 20)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let message = statusMessage(for: health) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(statusColor(for: health))
                }
            }
            Spacer()
            statusIndicator(health)
        }
    }

    private func refreshConnectorHealth() async {
        guard let hub = model.hub else { return }
        connectorHealth = Dictionary(
            uniqueKeysWithValues: await hub.healthSnapshots().map { ($0.id, $0.health) })
    }

    private func refreshMessageSafetyCount() {
        pendingSenderCount = (try? model.stores?
            .pendingMessageSourceObservationCount()) ?? 0
    }

    private func combinedHealth(for ids: [String]) -> ConnectorHealth? {
        let states = ids.compactMap { connectorHealth[$0] }
        if let failed = states.first(where: {
            if case .error = $0 { true } else { false }
        }) { return failed }
        if let blocked = states.first(where: {
            if case .needsAuthentication = $0 { true } else { false }
        }) { return blocked }
        if states.contains(.ready) { return .ready }
        return states.first
    }

    @ViewBuilder
    private func statusIndicator(_ health: ConnectorHealth?) -> some View {
        switch health {
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsAuthentication:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .disabled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private func statusMessage(for health: ConnectorHealth?) -> String? {
        switch health {
        case .needsAuthentication(let message), .error(let message): message
        case .disabled: "Disabled"
        case .ready, nil: nil
        }
    }

    private func statusColor(for health: ConnectorHealth?) -> Color {
        if case .error = health { return .red }
        if case .needsAuthentication = health { return .orange }
        return .secondary
    }

    // MARK: Active connection discovery

    struct ActiveConnection: Identifiable {
        let id: String
        let kind: ConnectionKind
        let title: String
        let subtitle: String
    }

    private var activeConnections: [ActiveConnection] {
        var result: [ActiveConnection] = []
        guard model.integrations?.externalIntegrationsDisabled != true else { return result }
        let keychain = model.keychain
        let stores = model.stores

        if (try? keychain.get("telegram.botToken")) ?? nil != nil {
            result.append(.init(id: "telegram", kind: .telegram, title: "Telegram",
                                subtitle: "Urgent pushes to your phone"))
        }
        if (try? keychain.get("moodle.icalURL")) ?? nil != nil {
            result.append(.init(id: "moodle", kind: .moodle, title: "Moodle",
                                subtitle: "Deadlines via calendar export"))
        }
        for (id, kind, name) in [("homeassistant", ConnectionKind.homeassistant, "Home Assistant")] {
            if let stores,
               let base = try? stores.value(forKey: "\(id).baseURL"),
               !base.isEmpty {
                result.append(.init(id: id, kind: kind, title: name, subtitle: base))
            }
        }
        if model.integrations?.weatherEnabled == true {
            result.append(.init(id: "weather", kind: .weather, title: "Weather",
                                subtitle: "Open-Meteo, no key"))
        }
        if model.integrations?.focusCoach?.isEnabled == true {
            result.append(.init(id: "focus", kind: .focus, title: "Focus Coach",
                                subtitle: "Goal tracking, drift nudges, break reminders"))
        }
        if model.integrations?.notificationsReaderEnabled == true {
            result.append(.init(id: "notifications", kind: .notifications, title: "System Notifications",
                                subtitle: "Sandboxed helper reads Notification Center"))
        }
        for customID in model.integrations?.customConnectorIDs ?? [] {
            result.append(.init(id: customID, kind: .custom, title: customID,
                                subtitle: "Custom API connector"))
        }
        return result
    }

    private func remove(_ connection: ActiveConnection) {
        Task {
            do {
                if connection.kind == .custom {
                    try await model.integrations?.removeCustomManifest(id: connection.id)
                } else {
                    try await model.integrations?.removeBuiltIn(id: connection.id)
                }
                refresh += 1
            } catch {
                model.presentError(title: "Connection could not be removed", error: error)
            }
        }
    }
}

// MARK: - Trusted message senders

private struct MessageSafetySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var pending: [MessageSourceObservation] = []
    @State private var trusted: [TrustedMessageSource] = []
    @State private var newAddress = ""
    @State private var domainCandidate: MessageSourceObservation?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Approval is not sender verification")
                                .font(.headline)
                            Text("Email From fields and notification labels can be spoofed, and a real contact's account can be compromised. Approved messages stay quarantined: no personal memory, Knowledge, web, mail, files, or automatic actions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Waiting for review") {
                    if pending.isEmpty {
                        ContentUnavailableView(
                            "No unknown senders",
                            systemImage: "checkmark.shield",
                            description: Text("New sender identities will appear here without their message content."))
                    } else {
                        ForEach(pending) { observation in
                            observationRow(observation)
                        }
                    }
                }

                Section("Trusted for quarantined processing") {
                    if trusted.isEmpty {
                        Text("No senders are trusted yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(trusted) { source in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: source.kind))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.label)
                                Text(ruleDescription(source))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                remove(source)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                Section("Add an exact mail address") {
                    HStack {
                        TextField("person@example.org", text: $newAddress)
                            .textContentType(.emailAddress)
                        Button("Trust address") { addAddress() }
                            .disabled(newAddress.trimmingCharacters(
                                in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("For shared providers such as Gmail, GMX, Web.de or iCloud, individual addresses are the only allowed option.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Trusted senders")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 620)
        .task { reload() }
        .alert(
            "Message safety could not be changed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            domainCandidate.map { "Trust every address at \($0.domain ?? "this domain")?" }
                ?? "Trust this domain?",
            isPresented: Binding(
                get: { domainCandidate != nil },
                set: { if !$0 { domainCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Trust exact domain", role: .destructive) {
                if let candidate = domainCandidate { trustDomain(candidate) }
                domainCandidate = nil
            }
            Button("Cancel", role: .cancel) { domainCandidate = nil }
        } message: {
            Text("This accepts any matching From address at that domain for assistant triage. It is not proof of DKIM/DMARC authentication, and compromised accounts remain dangerous.")
        }
    }

    @ViewBuilder
    private func observationRow(_ observation: MessageSourceObservation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(for: observation.kind))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(observation.displayName)
                    Text(observationDetail(observation))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("\(observation.messageCount) message\(observation.messageCount == 1 ? "" : "s") held · last seen \(observation.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            HStack {
                if observation.canApproveExactSender {
                    Button(observation.kind == .emailAddress
                           ? "Trust this address" : "Trust this app label") {
                        trustExact(observation)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Text("Identity could not be parsed; this sender cannot be trusted.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let domain = observation.domain {
                    if MessageTrustPolicy.isBroadMailboxDomain(domain) {
                        Text("Shared domain — address only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Trust \(domain)…") {
                            domainCandidate = observation
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                Spacer()
                Button("Dismiss") { dismissObservation(observation) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private func reload() {
        guard let stores = model.stores else { return }
        do {
            pending = try stores.pendingMessageSourceObservations()
            trusted = try stores.trustedMessageSources()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func trustExact(_ observation: MessageSourceObservation) {
        guard let stores = model.stores else { return }
        do {
            _ = try stores.trustMessageSource(
                kind: observation.kind,
                value: observation.value,
                applicationID: observation.applicationID,
                label: observation.displayName)
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func trustDomain(_ observation: MessageSourceObservation) {
        guard let stores = model.stores, let domain = observation.domain else { return }
        do {
            _ = try stores.trustMessageSource(
                kind: .emailDomain,
                value: domain,
                label: domain)
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func addAddress() {
        guard let stores = model.stores else { return }
        do {
            _ = try stores.trustMessageSource(
                kind: .emailAddress,
                value: newAddress,
                label: newAddress)
            newAddress = ""
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func dismissObservation(_ observation: MessageSourceObservation) {
        guard let stores = model.stores else { return }
        do {
            try stores.dismissMessageSourceObservation(observation.id)
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func remove(_ source: TrustedMessageSource) {
        guard let stores = model.stores else { return }
        do {
            try stores.removeTrustedMessageSource(source.id)
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func icon(for kind: TrustedMessageSourceKind) -> String {
        switch kind {
        case .emailAddress: "envelope"
        case .emailDomain: "at"
        case .notificationSender: "app.badge"
        }
    }

    private func observationDetail(_ observation: MessageSourceObservation) -> String {
        switch observation.kind {
        case .emailAddress: observation.value
        case .notificationSender: "\(observation.applicationID) · \(observation.value)"
        case .emailDomain: observation.value
        }
    }

    private func ruleDescription(_ source: TrustedMessageSource) -> String {
        switch source.kind {
        case .emailAddress: source.value
        case .emailDomain: "all From addresses at \(source.value)"
        case .notificationSender: "\(source.applicationID) · \(source.value)"
        }
    }
}

// MARK: - Catalog

enum ConnectionKind: String, Identifiable, CaseIterable {
    case telegram, moodle, homeassistant, weather, focus, notifications, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .telegram: "Telegram"
        case .moodle: "Moodle"
        case .homeassistant: "Home Assistant"
        case .weather: "Weather"
        case .focus: "Focus Coach"
        case .notifications: "System Notifications"
        case .custom: "Custom API…"
        }
    }

    var blurb: String {
        switch self {
        case .telegram: "Urgent notifications to your phone via a bot"
        case .moodle: "Assignment deadlines from the calendar export"
        case .homeassistant: "Search entity states and control exact lights"
        case .weather: "Forecasts via Open-Meteo — no account needed"
        case .focus: "Day goals, gentle drift nudges, break reminders"
        case .notifications: "Read WhatsApp/Signal/any app notifications for urgent triage (sandboxed helper)"
        case .custom: "Any HTTP API — paste a manifest or let Claude draft one from the docs"
        }
    }

    var icon: String {
        switch self {
        case .telegram: "paperplane"
        case .moodle: "graduationcap"
        case .homeassistant: "house"
        case .weather: "cloud.sun"
        case .focus: "target"
        case .notifications: "bell.badge"
        case .custom: "wand.and.stars"
        }
    }
}

struct CatalogSheet: View {
    let onPick: (ConnectionKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Connection")
                .font(.title3.weight(.semibold))
            ForEach(ConnectionKind.allCases) { kind in
                Button {
                    onPick(kind)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: kind.icon).frame(width: 22)
                        VStack(alignment: .leading) {
                            Text(kind.title)
                            Text(kind.blurb).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

// MARK: - Whitelist editor (unchanged behavior, moved here)

struct WhitelistEditor: View {
    @Environment(AppModel.self) private var model
    @State private var whitelist = (AitvarasPreferences.current.stringArray(forKey: "autonomy.whitelist") ?? []).joined(separator: ", ")

    var body: some View {
        TextField("connector.tool, comma-separated (e.g. telegram.notify_phone)", text: $whitelist)
        Button("Save whitelist") {
            let entries = Set(whitelist.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty })
            model.updateWhitelist(entries)
        }
    }
}

private struct GatewayConnectionsSection: View {
    let handlesGatewayTokenLinks: Bool
    @Environment(AppModel.self) private var model
    @State private var launches: [GatewayLaunch] = []
    @State private var accounts: [GatewayUpstreamAccount] = []
    @State private var states: [UUID: Bool] = [:]
    @State private var projects: [WorkspaceProject] = []
    @State private var disabledGlobals: Set<String> = []
    @State private var selectedAccounts: [String: UUID] = [:]
    @State private var projectID: UUID?
    @State private var accountProjectID: UUID?
    @State private var adding = false
    @State private var accountsExpanded = false
    @State private var name = ""
    @State private var label = ""
    @State private var endpoint = ""
    @State private var authKind: GatewayUpstreamAuthKind = .oauth
    @State private var headerName = ""
    @State private var token = ""
    @State private var saving = false
    @State private var tokenEditor: GatewayUpstreamAccount?
    @State private var command: GatewayCommandInstaller.Status?
    @State private var error: String?

    var body: some View {
        Section("Agent gateway") {
            commandRow
            DisclosureGroup("Live launches (\(launches.count))") {
                if launches.isEmpty { Text("No active agent launches.").foregroundStyle(.secondary) }
                ForEach(launches) { launch in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(launch.context.client.rawValue.capitalized)
                            Text(projectName(launch.context.projectID) + " · " + started(launch).formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke") { Task { await revoke(launch) } }
                            .buttonStyle(.bordered)
                    }
                }
            }

            DisclosureGroup("Upstream accounts (\(accounts.count))", isExpanded: $accountsExpanded) {
                ForEach(accounts) { account in accountRow(account) }
                DisclosureGroup("Add upstream account", isExpanded: $adding) {
                    TextField("Server name", text: $name)
                    TextField("Account label", text: $label)
                    TextField("MCP HTTPS URL", text: $endpoint)
                    Picker("Authentication", selection: $authKind) {
                        Text("OAuth").tag(GatewayUpstreamAuthKind.oauth)
                        Text("Fixed token").tag(GatewayUpstreamAuthKind.staticHeader)
                    }
                    .onChange(of: authKind) { token = "" }
                    if authKind == .staticHeader {
                        SecureField("Token", text: $token)
                        TextField("Custom header name (optional)", text: $headerName)
                            .help("Leave blank to send Authorization with the Bearer scheme.")
                    }
                    Picker("Availability", selection: $accountProjectID) {
                        Text("Global").tag(nil as UUID?)
                        ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
                    }
                    Button("Add account", action: addAccount)
                        .disabled(name.isEmpty || label.isEmpty || endpoint.isEmpty || (authKind == .staticHeader && token.isEmpty))
                }
                .disabled(saving)
                .onChange(of: adding) { if !adding { token = "" } }
            }

            if !projects.isEmpty, !accounts.isEmpty {
                Picker("Project routing", selection: $projectID) {
                    Text("Choose a project").tag(nil as UUID?)
                    ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
                }
                .onChange(of: projectID) { updateAssignments() }
                if let projectID {
                    ForEach(Array(Set(availableAccounts(projectID).map(\.serverName))).sorted(), id: \.self) { server in
                        projectRouting(server, projectID: projectID)
                    }
                }
            }
            if let message = error ?? model.gatewaySignInError { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: model.gatewayTokenAccountToEdit, initial: true) { _, accountID in
            guard handlesGatewayTokenLinks, let accountID else { return }
            model.gatewayTokenAccountToEdit = nil
            if let account = try? model.stores?.gatewayUpstream(id: accountID).account, account.authKind == .staticHeader {
                accountsExpanded = true
                tokenEditor = account
            }
        }
        .sheet(item: $tokenEditor) { account in
            GatewayTokenEditor(account: account)
        }
        .task {
            command = try? model.gatewayCommandInstaller.status()
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var commandRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch command {
            case .installed:
                Button("Uninstall command-line tool") { changeCommand(install: false) }
            case .absent:
                Button("Install command-line tool") { changeCommand(install: true) }
            case .occupied:
                Text("~/.local/bin/aitvaras is already in use.")
            case nil:
                Text("Command installation is unavailable.")
            }
            Text("~/.local/bin/aitvaras").font(.caption.monospaced()).foregroundStyle(.secondary)
            if !model.gatewayCommandOnPath {
                Text("~/.local/bin is not on your PATH. Add it to your shell’s PATH or run the command using its full path.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func accountRow(_ account: GatewayUpstreamAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(account.displayName)
                    let status = accountStatus(account)
                    Text("\(account.serverName) · \(availability(account)) · \(status)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if account.authKind == .staticHeader {
                    let hasToken = states[account.id] == true || tokenWasRejected(account)
                    Button(hasToken ? "Replace token" : "Set token") { tokenEditor = account }
                        .buttonStyle(.bordered)
                    if hasToken {
                        Button("Remove token") { Task { await signOut(account.id) } }.buttonStyle(.bordered)
                    }
                } else if model.gatewaySigningIn == account.id {
                    Button("Cancel") { model.cancelGatewaySignIn() }.buttonStyle(.bordered)
                } else if states[account.id] == true {
                    Button("Sign out") { Task { await signOut(account.id) } }.buttonStyle(.bordered)
                } else {
                    Button("Sign in") { model.startGatewaySignIn(account.id) }
                        .buttonStyle(.bordered)
                        .disabled(model.gatewaySigningIn != nil || states[account.id] == nil)
                }
            }
            Toggle("Trust MCP tool annotations", isOn: Binding(get: { account.trusted }, set: { trusted in
                changeRouting { try $0.setGatewayUpstreamTrust(id: account.id, trusted: trusted) }
            }))
            .help(account.authKind == .staticHeader
                ? "Trust allows eligible read-only tools to run without confirmation."
                : "Trust can let eligible upstream tools run without confirmation.")
            if account.globallyAvailable {
                Toggle("Global default", isOn: Binding(get: { account.isGlobalDefault }, set: { global in
                    changeRouting { try $0.setGatewayGlobalDefault(serverName: account.serverName, accountID: global ? account.id : nil) }
                }))
            }
        }
    }

    private func tokenWasRejected(_ account: GatewayUpstreamAccount) -> Bool {
        model.gatewaySignInRequests.contains { $0.id == account.id && $0.tokenRejected }
    }

    private func accountStatus(_ account: GatewayUpstreamAccount) -> String {
        guard let active = states[account.id] else { return "Credential status unavailable" }
        if account.authKind == .oauth { return active ? "Signed in" : "Signed out" }
        if tokenWasRejected(account) { return "Token rejected" }
        return active ? "Token stored" : "Token required"
    }

    private func addAccount() {
        if authKind == .oauth {
            changeRouting {
                try $0.addGatewayUpstream(serverName: name, label: label, endpoint: endpoint, projectID: accountProjectID)
                resetEntry()
            }
            return
        }
        let submitted = token
        token = ""
        let header = headerName.trimmingCharacters(in: .whitespaces)
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.addGatewayStaticUpstream(serverName: name, label: label, endpoint: endpoint,
                    projectID: accountProjectID, headerName: header.isEmpty ? nil : header, token: submitted)
                error = nil
                resetEntry()
                await refresh()
            } catch let failure as GatewayUpstreamError {
                error = failure.errorDescription
            } catch {
                self.error = "Could not add the fixed-token account. Check the HTTPS URL, server name, project, and Keychain access."
            }
        }
    }

    private func resetEntry() {
        name = ""; label = ""; endpoint = ""; headerName = ""; token = ""; adding = false
    }

    private func projectRouting(_ server: String, projectID: UUID) -> some View {
        let eligible = availableAccounts(projectID).filter { $0.serverName == server }
        let globalEnabled = !disabledGlobals.contains(server)
        return VStack(alignment: .leading, spacing: 6) {
            if eligible.contains(where: \.globallyAvailable) {
                Toggle("Allow global \(server) accounts", isOn: Binding(get: { globalEnabled }, set: { enabled in
                    changeRouting { try $0.editAgentSetup(projectID: projectID, edit: .globalEnabled(name: server, enabled: enabled)) }
                }))
            }
            Picker("\(server) account", selection: Binding(get: { selectedAccounts[server] }, set: { accountID in
                changeRouting { try $0.selectGatewayUpstreamAccount(projectID: projectID, serverName: server, accountID: accountID) }
            })) {
                Text("Use global default if allowed").tag(nil as UUID?)
                ForEach(eligible) { account in
                    Text(account.displayName + (account.globallyAvailable && !globalEnabled ? " (opted out)" : ""))
                        .tag(Optional(account.id))
                        .disabled(account.globallyAvailable && !globalEnabled)
                }
            }
        }
    }

    private func availableAccounts(_ project: UUID) -> [GatewayUpstreamAccount] {
        accounts.filter { $0.definitionProjectID == nil || $0.definitionProjectID == project }
    }

    private func projectName(_ id: UUID?) -> String {
        guard let id else { return "No project" }
        return projects.first { $0.id == id }?.title ?? "Unavailable project"
    }

    private func availability(_ account: GatewayUpstreamAccount) -> String {
        if account.globallyAvailable { return "Global" }
        return account.definitionProjectID.map { projectName($0) } ?? "By project selection"
    }

    private func started(_ launch: GatewayLaunch) -> Date {
        Date(timeIntervalSince1970: Double(launch.root.startSeconds) + Double(launch.root.startMicroseconds) / 1_000_000)
    }

    private func refresh() async {
        launches = await model.gatewayLiveLaunches().sorted { started($0) > started($1) }
        guard let stores = model.stores else { return }
        if let rows = try? stores.allGatewayUpstreamAccounts() { accounts = rows }
        if let rows = try? stores.workspaceProjects(includeHidden: false) { projects = rows }
        updateAssignments()
        var current: [UUID: Bool] = [:]
        for account in accounts {
            current[account.id] = try? await model.gatewayAccountSignedIn(account.id)
        }
        states = current
    }

    private func updateAssignments() {
        let values = projectID.flatMap { id in try? model.stores?.gatewayProjectAssignments(projectID: id) }
        disabledGlobals = values?.disabled ?? []
        selectedAccounts = values?.selected ?? [:]
    }

    private func changeRouting(_ operation: (Stores) throws -> Void) {
        guard let stores = model.stores else { return }
        do {
            try operation(stores)
            error = nil
            accounts = try stores.allGatewayUpstreamAccounts()
            updateAssignments()
            Task { await model.refreshGatewayRouting(); await refresh() }
        } catch { self.error = "Could not save the gateway setting. Check the server name, HTTPS URL, and project." }
    }

    private func changeCommand(install: Bool) {
        do {
            try model.changeGatewayCommand(install: install)
            error = nil
        } catch { self.error = (error as? GatewayCommandInstaller.Failure)?.errorDescription ?? "Could not change command installation." }
        command = try? model.gatewayCommandInstaller.status()
    }

    private func revoke(_ launch: GatewayLaunch) async {
        do { try await model.revokeGatewayLaunch(launch); error = nil }
        catch { self.error = "Could not revoke the launch." }
        await refresh()
    }

    private func signOut(_ id: UUID) async {
        do { try await model.signOutGatewayAccount(id); error = nil }
        catch { self.error = "Could not remove the account credential." }
        await refresh()
    }
}

private struct GatewayTokenEditor: View {
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
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save token", action: save).keyboardShortcut(.defaultAction).disabled(token.isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled(saving)
        .onAppear { tokenFocused = true }
    }

    private func save() {
        let submitted = token
        token = ""
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.replaceGatewayToken(account.id, token: submitted)
                dismiss()
            } catch let failure as GatewayUpstreamError {
                error = failure.errorDescription
            } catch {
                self.error = "Could not save the token. Check Keychain access."
            }
        }
    }
}
