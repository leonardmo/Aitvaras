import SwiftUI
import AitvarasCore
import AitvarasConnectors

/// Connections: unconfigured by default, everything added through one
/// "Add Connection" flow (user decision 2026-07-06). Custom APIs are
/// first-class — paste a manifest, or let Claude draft one from docs.
struct ConnectorsView: View {
    @Environment(AppModel.self) private var model
    @State private var showCatalog = false
    @State private var configuringKind: ConnectionKind?
    @State private var refresh = 0

    var body: some View {
        List {
            Section {
                Text("Read tools run freely; writes ask for confirmation unless whitelisted. Secrets live only in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Always available") {
                builtInRow(name: "Calendar & Reminders", icon: "calendar",
                           detail: "Creates into your 'Aitvaras' calendar/list")
                builtInRow(name: "Apple Mail", icon: "envelope",
                           detail: "Read + search only — sending is not built in")
                builtInRow(name: "Web search", icon: "globe",
                           detail: "DuckDuckGo search + page reading")
                builtInRow(name: "Daily goals", icon: "target",
                           detail: "Plan the day together in chat or voice")
                builtInRow(name: "Knowledge (RAG)", icon: "books.vertical",
                           detail: "Studium + Cealonet, see Knowledge tab")
                builtInRow(name: "Claude delegation", icon: "terminal",
                           detail: ManifestDrafter.isAvailable()
                               ? "CLI found — heavy tasks can be delegated (always asks first)"
                               : "Install: npm install -g @anthropic-ai/claude-code")
            }

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
                        }
                        Spacer()
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

            Section("Autonomy whitelist") {
                WhitelistEditor()
            }
        }
        .id(refresh)
        .navigationTitle("Connections")
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
    }

    private func builtInRow(name: String, icon: String, detail: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 20)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green.opacity(0.7))
        }
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
        let keychain = model.keychain
        let stores = model.stores

        if (try? keychain.get("telegram.botToken")) ?? nil != nil {
            result.append(.init(id: "telegram", kind: .telegram, title: "Telegram",
                                subtitle: "Urgent pushes to your phone"))
        }
        if (try? keychain.get("moodle.icalURL")) ?? nil != nil {
            result.append(.init(id: "moodle", kind: .moodle, title: "Moodle (TUM)",
                                subtitle: "Deadlines via calendar export"))
        }
        for (id, kind, name) in [("proxmox", ConnectionKind.proxmox, "Proxmox"),
                                 ("truenas", .truenas, "TrueNAS"),
                                 ("homeassistant", .homeassistant, "Home Assistant")] {
            if let base = try? stores?.value(forKey: "\(id).baseURL"), !(base ?? "").isEmpty {
                result.append(.init(id: id, kind: kind, title: name, subtitle: base ?? ""))
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
            if connection.kind == .custom {
                await model.integrations?.removeCustomManifest(id: connection.id)
            } else {
                await model.integrations?.removeBuiltIn(id: connection.id)
            }
            refresh += 1
        }
    }
}

// MARK: - Catalog

enum ConnectionKind: String, Identifiable, CaseIterable {
    case telegram, moodle, proxmox, truenas, homeassistant, weather, focus, notifications, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .telegram: "Telegram"
        case .moodle: "Moodle (TUM)"
        case .proxmox: "Proxmox"
        case .truenas: "TrueNAS"
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
        case .proxmox: "Read-only cluster status"
        case .truenas: "Read-only system and pool status"
        case .homeassistant: "Read-only entity states"
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
        case .proxmox: "server.rack"
        case .truenas: "externaldrive"
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
    @State private var whitelist = (UserDefaults.standard.stringArray(forKey: "autonomy.whitelist") ?? []).joined(separator: ", ")

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
