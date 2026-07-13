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

    // Custom API
    @State private var breakInterval = 50
    @State private var macShortcut = ""
    @State private var manifestJSON = ""
    @State private var draftDescription = ""
    @State private var draftDocsURL = ""
    @State private var validationResult = ""
    @State private var secretValue = ""
    @State private var neededKeychainKey: String?

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
                Button("Cancel") { onDone() }.keyboardShortcut(.escape)
                Button(busy ? "Working…" : "Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !isValid)
            }
        }
        .padding(22)
        .frame(width: kind == .custom ? 620 : 460)
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
        case .proxmox, .truenas, .homeassistant:
            TextField("Base URL, e.g. https://host:8006", text: $field1)
            SecureField("API token (read-only account/role!)", text: $field2)
        case .weather:
            Text("No configuration needed — Open-Meteo is keyless and free.")
        case .focus:
            VStack(alignment: .leading, spacing: 10) {
                Text("A Focus Session is one thing you start when you want to concentrate. While it runs, Aitvaras: holds non-urgent notifications and delivers them as a spoken briefing at each break; watches which app is frontmost (locally, in memory) and gently nudges only on sustained drift from today's goals; reminds you to break on your chosen cadence; and gives a short summary when you end it. Start one by saying \u{201C}let's focus\u{201D} or with the moon button on the companion.")
                    .font(.callout)
                Stepper("Break reminder every \(breakInterval) min", value: $breakInterval, in: 15...120, step: 5)
                Text("macOS won't hide app banners on its own. Optional: create a macOS Focus + a Shortcut that turns it on, name it below, and Aitvaras runs it when a session starts (and \u{201C}<name> Off\u{201D} when it ends). Otherwise toggle Do Not Disturb yourself; Aitvaras still reads and re-surfaces the hidden ones.")
                    .font(.caption).foregroundStyle(.tertiary)
                TextField("Shortcut name (optional, e.g. 'Aitvaras Focus')", text: $macShortcut)
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
        GroupBox("Let Claude draft it (recommended)") {
            TextField("What should this connector do?", text: $draftDescription)
            TextField("API docs URL (optional but helps a lot)", text: $draftDocsURL)
            Button(busy ? "Claude is reading the docs…" : "Draft manifest with Claude") {
                draftWithClaude()
            }
            .disabled(busy || draftDescription.isEmpty || !ManifestDrafter.isAvailable())
            if !ManifestDrafter.isAvailable() {
                Text("Claude CLI missing — npm install -g @anthropic-ai/claude-code")
                    .font(.caption).foregroundStyle(.orange)
            }
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
        case .proxmox, .truenas, .homeassistant: !field1.isEmpty && !field2.isEmpty
        case .weather, .focus, .notifications: true
        case .custom: !manifestJSON.isEmpty
        }
    }

    private func connect() {
        busy = true
        Task {
            defer { busy = false }
            guard let integrations = model.integrations else { return }
            switch kind {
            case .telegram:
                try? model.keychain.set(field1, forKey: "telegram.botToken")
                if let telegram = await model.hub?.connectors["telegram"] as? TelegramConnector {
                    if let chatID = try? await telegram.discoverChatID() {
                        status = "Connected — chat \(chatID). Test message sent."
                        try? await telegram.testMessage()
                    } else {
                        status = "Token saved. Send your bot a message, then reopen this dialog to finish detection."
                        return
                    }
                }
                onDone()
            case .moodle:
                try? model.keychain.set(field1, forKey: "moodle.icalURL")
                onDone()
            case .proxmox, .truenas, .homeassistant:
                let id = kind.rawValue
                try? model.stores?.setValue(field1, forKey: "\(id).baseURL")
                let tokenKey = id == "proxmox" ? BundledManifests.proxmoxTokenKey
                    : id == "truenas" ? BundledManifests.trueNASTokenKey
                    : BundledManifests.homeAssistantTokenKey
                try? model.keychain.set(field2, forKey: tokenKey)
                await integrations.registerHomelab()
                onDone()
            case .weather:
                await integrations.enableWeather()
                onDone()
            case .focus:
                integrations.focusCoach?.setEnabled(true)
                integrations.focusCoach?.setBreakInterval(minutes: breakInterval)
                try? model.stores?.setValue(macShortcut, forKey: FocusCoach.macFocusShortcutKey)
                onDone()
            case .notifications:
                await integrations.enableNotificationsReader()
                if let reader = await model.hub?.connectors["notifications"],
                   case .needsAuthentication(let message) = await reader.health() {
                    status = message
                    return
                }
                onDone()
            case .custom:
                if let key = neededKeychainKey, !secretValue.isEmpty {
                    try? model.keychain.set(secretValue, forKey: key)
                }
                do {
                    try await integrations.addCustomManifest(manifestJSON)
                    onDone()
                } catch {
                    status = "Invalid manifest: \(error.localizedDescription)"
                }
            }
        }
    }

    private func validate() {
        guard let data = manifestJSON.data(using: .utf8) else { return }
        do {
            let manifest = try JSONDecoder().decode(ConnectorManifest.self, from: data)
            validationResult = "✓ \(manifest.displayName): \(manifest.tools.count) tools" +
                (manifest.triggers.isEmpty ? "" : ", \(manifest.triggers.count) triggers")
            neededKeychainKey = manifest.auth.keychainKey
        } catch {
            validationResult = "✗ \(error.localizedDescription)"
            neededKeychainKey = nil
        }
    }

    private func draftWithClaude() {
        busy = true
        status = "Claude is drafting the connector — this takes a minute…"
        Task {
            defer { busy = false }
            do {
                manifestJSON = try await ManifestDrafter.draft(
                    description: draftDescription, docsURL: draftDocsURL)
                validate()
                status = "Draft ready — review the JSON, validate, then Connect."
            } catch {
                status = "Drafting failed: \(error.localizedDescription)"
            }
        }
    }
}
