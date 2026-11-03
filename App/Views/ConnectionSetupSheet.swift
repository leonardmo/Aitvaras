import SwiftUI
import AitvarasConnectors

/// Per-type setup forms for the Add Connection flow.
struct ConnectionSetupSheet: View {
    @Environment(AppModel.self) private var model
    let kind: ConnectionKind
    let onDone: () -> Void

    @State private var field1 = ""      // token / url / base url
    @State private var field2 = ""      // secondary secret
    @State private var status = ""
    @State private var busy = false
    @State private var hasExistingHomeAssistantToken = false

    // Custom API
    @State private var breakInterval = 50
    @State private var macShortcut = ""
    @State private var manifestJSON = ""
    @State private var draftDescription = ""
    @State private var draftDocsURL = ""
    @State private var validationResult = ""
    @State private var secretValue = ""
    @State private var neededKeychainKey: String?
    @State private var draftTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(kind.title, systemImage: kind.icon)
                .font(.title3.weight(.semibold))
            Text(kind.blurb).font(.callout).foregroundStyle(.secondary)

            form

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    draftTask?.cancel()
                    onDone()
                }
                .keyboardShortcut(.escape)
                Button(busy ? "Working…" : "Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !isValid)
            }
        }
        .padding(22)
        .frame(width: kind == .custom ? 620 : 460)
        .onAppear {
            if kind == .homeassistant {
                hasExistingHomeAssistantToken = (try? model.keychain.allKeys()
                    .contains(BundledManifests.homeAssistantTokenKey)) == true
            }
        }
        .onDisappear { draftTask?.cancel() }
    }

    @ViewBuilder
    private var form: some View {
        switch kind {
        case .telegram:
            SecureField("Bot token (from @BotFather)", text: $field1)
            Text("Create a bot with @BotFather, paste its token, then send your bot any message so the chat can be detected.")
                .font(.caption).foregroundStyle(.tertiary)
        case .moodle:
            SecureField("Calendar export URL", text: $field1)
            Text("Moodle → Preferences → Calendar → Export calendar → all events → copy URL.")
                .font(.caption).foregroundStyle(.tertiary)
        case .proxmox, .truenas:
            TextField("Base URL, e.g. https://host:8006", text: $field1)
            SecureField("API token (read-only account/role!)", text: $field2)
        case .homeassistant:
            TextField("Home Assistant URL, e.g. http://homeassistant.local:8123", text: $field1)
            SecureField(
                hasExistingHomeAssistantToken
                    ? "New token (leave blank to keep Keychain token)"
                    : "Long-lived access token",
                text: $field2)
            Text("Aitvaras verifies the connection before saving. The token stays only in your macOS Keychain; the URL stays only in local app state. A dedicated non-admin Home Assistant user is recommended.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .weather:
            Text("No configuration needed — Open-Meteo is keyless and free.")
        case .focus:
            VStack(alignment: .leading, spacing: 10) {
                Text("Focus sessions hold non-urgent notifications, remind you to take breaks and gently nudge you back to today's goals.")
                    .font(.callout)
                DisclosureGroup("How focus sessions work") {
                    Text("A Focus Session is one thing you start when you want to concentrate. While it runs, Aitvaras: holds non-urgent notifications and delivers them as a spoken briefing at each break; watches which app is frontmost (locally, in memory) and gently nudges only on sustained drift from today's goals; reminds you to break on your chosen cadence; and gives a short summary when you end it. Start one by saying \u{201C}let's focus\u{201D} or with the moon button on the companion.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper("Break reminder every \(breakInterval) min", value: $breakInterval, in: 15...120, step: 5)
                TextField("Shortcut name (optional, e.g. 'Aitvaras Focus')", text: $macShortcut)
                DisclosureGroup("Optional macOS Focus setup") {
                    Text("macOS won't hide app banners on its own. Optional: create a macOS Focus + a Shortcut that turns it on, enter its name above, and Aitvaras runs it when a session starts (and \u{201C}<name> Off\u{201D} when it ends). Otherwise toggle Do Not Disturb yourself; Aitvaras still reads and re-surfaces the hidden ones.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .notifications:
            notificationsForm
        case .custom:
            customForm
        }
    }

    @ViewBuilder
    private var notificationsForm: some View {
        Text("Reads Notification Center (WhatsApp, Signal, …) so time-sensitive messages reach you even in focus mode. Aitvaras itself gets NO Full Disk Access — only the tiny sandboxed helper below does. The helper is kernel-locked: no network, no writes, no file access beyond the notification database.")
            .font(.callout)
        if let helper = NotificationsConnector.helperURL {
            GroupBox("Grant Full Disk Access to the helper (one time)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Click below to open the Full Disk Access settings\n2. Click +, press ⌘⇧G, paste this path, click Open:")
                        .font(.caption)
                    HStack {
                        Text(helper.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(helper.path, forType: .string)
                        }
                        .controlSize(.small)
                    }
                    Link("Open Full Disk Access settings",
                         destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
        }
    }

    @ViewBuilder
    private var customForm: some View {
        GroupBox("Draft with your selected cloud agent") {
            TextField("What should this connector do?", text: $draftDescription)
            TextField("API docs URL (optional but helps a lot)", text: $draftDocsURL)
            Button(busy ? "Creating draft…" : "Draft connector") {
                draftWithCloudAgent()
            }
            .disabled(busy || draftDescription.isEmpty || !ManifestDrafter.isAvailable())
            if !ManifestDrafter.isAvailable() {
                Text(ManifestDrafter.configuredSelection() == .local
                     ? "Cloud drafting is off. Choose a provider under Models → Cloud agents, or enter JSON manually."
                     : "The selected Claude Code/Codex CLI is not installed. Install it and sign in once.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(CloudAgentFeature.connectorDrafting.disclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("Manifest JSON")
            .font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $manifestJSON)
            .font(.caption.monospaced())
            .frame(height: 220)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
        HStack {
            Button("Validate") { validate() }
                .disabled(manifestJSON.isEmpty)
            Text(validationResult).font(.caption).foregroundStyle(.secondary)
        }
        if let key = neededKeychainKey {
            SecureField("Secret for Keychain key '\(key)'", text: $secretValue)
        }
    }

    private var isValid: Bool {
        switch kind {
        case .telegram, .moodle: !field1.isEmpty
        case .proxmox, .truenas: !field1.isEmpty && !field2.isEmpty
        case .homeassistant:
            !field1.isEmpty && (!field2.isEmpty || hasExistingHomeAssistantToken)
        case .weather, .focus, .notifications: true
        case .custom: !manifestJSON.isEmpty
        }
    }

    private func connect() {
        busy = true
        Task {
            defer { busy = false }
            guard let integrations = model.integrations, let stores = model.stores else {
                status = "Aitvaras is not ready yet. Please try again in a moment."
                return
            }
            do {
                switch kind {
                case .telegram:
                    try model.keychain.set(field1, forKey: "telegram.botToken")
                    guard let telegram = await model.hub?.connectors["telegram"] as? TelegramConnector else {
                        throw ConnectorError("Telegram connector is unavailable.")
                    }
                    let chatID: String
                    do {
                        chatID = try await telegram.discoverChatID()
                    } catch {
                        status = "Token saved. \(error.localizedDescription)"
                        return
                    }
                    try await telegram.testMessage()
                    status = "Connected — chat \(chatID). Test message sent."
                    onDone()
                case .moodle:
                    try model.keychain.set(field1, forKey: "moodle.icalURL")
                    onDone()
                case .proxmox, .truenas:
                    let id = kind.rawValue
                    let tokenKey = id == "proxmox" ? BundledManifests.proxmoxTokenKey
                        : BundledManifests.trueNASTokenKey
                    try model.keychain.set(field2, forKey: tokenKey)
                    try stores.setValue(field1, forKey: "\(id).baseURL")
                    try await integrations.registerHomelab()
                    onDone()
                case .homeassistant:
                    status = "Verifying Home Assistant…"
                    try await integrations.configureHomeAssistant(
                        baseURL: field1, token: field2)
                    status = "Connected."
                    onDone()
                case .weather:
                    try await integrations.enableWeather()
                    onDone()
                case .focus:
                    guard let focusCoach = integrations.focusCoach else {
                        throw ConnectorError("Focus Coach is unavailable.")
                    }
                    try focusCoach.setBreakInterval(minutes: breakInterval)
                    try stores.setValue(macShortcut, forKey: FocusCoach.macFocusShortcutKey)
                    try focusCoach.setEnabled(true)
                    onDone()
                case .notifications:
                    try await integrations.enableNotificationsReader()
                    if let reader = await model.hub?.connectors["notifications"],
                       case .needsAuthentication(let message) = await reader.health() {
                        status = message
                        return
                    }
                    onDone()
                case .custom:
                    if let key = neededKeychainKey, !secretValue.isEmpty {
                        try model.keychain.set(secretValue, forKey: key)
                    }
                    try await integrations.addCustomManifest(manifestJSON)
                    onDone()
                }
            } catch {
                status = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    private func validate() {
        guard let data = manifestJSON.data(using: .utf8) else { return }
        do {
            let manifest = try ConnectorManifest.decodeAndValidate(data)
            validationResult = "✓ \(manifest.displayName): \(manifest.tools.count) tools" +
                (manifest.triggers.isEmpty ? "" : ", \(manifest.triggers.count) triggers")
            neededKeychainKey = manifest.auth.keychainKey
        } catch {
            validationResult = "✗ \(error.localizedDescription)"
            neededKeychainKey = nil
        }
    }

    private func draftWithCloudAgent() {
        draftTask?.cancel()
        busy = true
        status = "The selected cloud agent is drafting the connector…"
        draftTask = Task {
            defer {
                busy = false
                draftTask = nil
            }
            do {
                guard let stores = model.stores else {
                    throw ConnectorError("Aitvaras is not ready yet.")
                }
                let draft = try await ManifestDrafter.draft(
                    description: draftDescription,
                    docsURL: draftDocsURL,
                    stores: stores)
                manifestJSON = draft.json
                try Task.checkCancellation()
                validate()
                status = "\(draft.provider.displayName) draft ready — review the JSON, validate, then Connect."
            } catch is CancellationError {
                status = "Draft cancelled."
            } catch {
                status = "Drafting failed: \(error.localizedDescription)"
            }
        }
    }
}
