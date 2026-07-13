import Foundation
import CoreGraphics
import Observation
import UserNotifications
import AitvarasCore
import AitvarasStore
import AitvarasAgent
import AitvarasEngines
import AitvarasConnectors
import AitvarasRAG

/// Wires connectors, RAG and the event triage pipeline (ARCHITECTURE.md
/// "Core flow"): connector events → light-model triage → activity log,
/// urgent Telegram pushes, and full agent turns for actionable mail.
@MainActor
@Observable
final class IntegrationCoordinator {
    let stores: Stores
    let keychain: KeychainStore
    let hub: ConnectorHub
    let router: EngineRouter

    private(set) var retriever: (any ContextRetriever)?
    /// Shared across RAG (doc index) and the memory connector (fact recall).
    private let embedder: any EmbeddingEngine = OllamaEmbedder()
    private var indexer: Indexer?
    private var sources: [IndexSource] = []
    private var mail: MailConnector?
    private var moodle: MoodleConnector?
    private var telegram: TelegramConnector?
    private var agentLoop: AgentLoop?
    private var pumpTask: Task<Void, Never>?
    private var homelabIDs: [String] = []
    private(set) var focusCoach: FocusCoach?
    private(set) var notifications: NotificationRouter?
    private var notificationsReader: NotificationsConnector?
    /// ids of custom-manifest connectors currently registered
    private(set) var customConnectorIDs: [String] = []

    static var customManifestsDirectory: URL {
        AitvarasPaths.connectorsDirectory
    }

    // UI-observable state
    var indexProgressText = ""
    var indexStats: (documents: Int, chunks: Int, embedded: Int) = (0, 0, 0)
    var isIndexing = false

    init(stores: Stores, keychain: KeychainStore, hub: ConnectorHub, router: EngineRouter) {
        self.stores = stores
        self.keychain = keychain
        self.hub = hub
        self.router = router
    }

    func attach(agentLoop: AgentLoop) {
        self.agentLoop = agentLoop
    }

    // MARK: Registration

    func registerAll() async {
        let mail = MailConnector(stores: stores)
        let telegram = TelegramConnector(keychain: keychain, stores: stores)
        let moodle = MoodleConnector(keychain: keychain, stores: stores)
        self.mail = mail
        self.telegram = telegram
        self.moodle = moodle

        await hub.register(CalendarConnector())
        await hub.register(RemindersConnector())
        await hub.register(mail)
        await hub.register(telegram)
        await hub.register(moodle)
        await hub.register(DelegateConnector())
        await hub.register(WebConnector())
        await hub.register(GoalsConnector(stores: stores))
        await hub.register(MemoryConnector(stores: stores, embedder: embedder))

        // Capture tools (F12): the model can open the setup panel and stop
        // sessions; starting always goes through the human consent panel.
        let captureConnector = CaptureConnector(stores: stores)
        await captureConnector.attach(
            openSetup: { await MainActor.run { AppModel.shared.openCaptureSetup() } },
            stop: { await AppModel.shared.stopCaptureFromTool() },
            status: { await MainActor.run { AppModel.shared.capture?.statusLine() ?? "No capture session running." } })
        await hub.register(captureConnector)
        // Open-Meteo manifests exist in BundledManifests but stay
        // unregistered — user declined for now (2026-07-06).
        await registerHomelab()
        await registerCustomManifests()
        if weatherEnabled { await enableWeather() }
        if notificationsReaderEnabled { await enableNotificationsReader() }
        setupRAG()

        let notificationRouter = NotificationRouter(stores: stores)
        notificationRouter.announce = { text in
            AppModel.shared.announce(text)
        }
        notifications = notificationRouter
        let coach = FocusCoach(stores: stores, router: router, notifications: notificationRouter)
        focusCoach = coach
        coach.startIfSessionActive()
    }

    /// Load user-created connector manifests (D17) from disk.
    func registerCustomManifests() async {
        let dir = Self.customManifestsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONDecoder().decode(ConnectorManifest.self, from: data),
                  !customConnectorIDs.contains(manifest.id) else { continue }
            let connector = GenericHTTPConnector(manifest: manifest, keychain: keychain, stores: stores)
            await hub.register(connector)
            await connector.startTriggers()
            customConnectorIDs.append(manifest.id)
        }
    }

    /// Save + activate a custom manifest from the creator flow.
    func addCustomManifest(_ json: String) async throws {
        guard let data = json.data(using: .utf8) else { throw ConnectorError("Not UTF-8") }
        let manifest = try JSONDecoder().decode(ConnectorManifest.self, from: data)
        let dir = Self.customManifestsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("\(manifest.id).json"))
        customConnectorIDs.removeAll { $0 == manifest.id }
        await hub.unregister(id: manifest.id)
        await registerCustomManifests()
    }

    func removeCustomManifest(id: String) async {
        try? FileManager.default.removeItem(
            at: Self.customManifestsDirectory.appendingPathComponent("\(id).json"))
        customConnectorIDs.removeAll { $0 == id }
        await hub.unregister(id: id)
    }

    /// Disconnect a built-in connection (clears its configuration).
    func removeBuiltIn(id: String) async {
        switch id {
        case "telegram":
            try? keychain.delete("telegram.botToken")
            try? stores.setValue("", forKey: "telegram.chatID")
        case "moodle":
            try? keychain.delete("moodle.icalURL")
        case "proxmox", "truenas", "homeassistant":
            try? stores.setValue("", forKey: "\(id).baseURL")
            await hub.unregister(id: id)
            homelabIDs.removeAll { $0 == id }
        case "weather":
            try? stores.setValue("", forKey: "weather.enabled")
            await hub.unregister(id: "weather")
            await hub.unregister(id: "geocode")
        case "focus":
            focusCoach?.setEnabled(false)
        case "notifications":
            await disableNotificationsReader()
        default:
            break
        }
    }

    func enableWeather() async {
        try? stores.setValue("1", forKey: "weather.enabled")
        await hub.register(GenericHTTPConnector(
            manifest: BundledManifests.openMeteoWeather(), keychain: keychain, stores: stores))
        await hub.register(GenericHTTPConnector(
            manifest: BundledManifests.openMeteoGeocoding(), keychain: keychain, stores: stores))
    }

    var weatherEnabled: Bool {
        (try? stores.value(forKey: "weather.enabled")) == "1"
    }

    var notificationsReaderEnabled: Bool {
        (try? stores.value(forKey: "notifications.enabled")) == "1"
    }

    func enableNotificationsReader() async {
        try? stores.setValue("1", forKey: "notifications.enabled")
        let reader = notificationsReader ?? NotificationsConnector(stores: stores)
        notificationsReader = reader
        await hub.register(reader)
        await reader.startPolling()
        await restartEventPump()
    }

    func disableNotificationsReader() async {
        try? stores.setValue("0", forKey: "notifications.enabled")
        await notificationsReader?.stopPolling()
        await hub.unregister(id: "notifications")
        notificationsReader = nil
    }

    /// mergedEvents() snapshots the connector list — after adding a
    /// connection with an event stream the pump must be rebuilt.
    func restartEventPump() async {
        guard pumpTask != nil else { return }
        pumpTask?.cancel()
        pumpTask = nil
        let events = await hub.mergedEvents()
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    /// Homelab connectors exist only when a base URL is configured (D10).
    func registerHomelab() async {
        let configs: [(kvKey: String, build: (String) -> ConnectorManifest)] = [
            ("proxmox.baseURL", BundledManifests.proxmox),
            ("truenas.baseURL", BundledManifests.trueNAS),
            ("homeassistant.baseURL", BundledManifests.homeAssistant)
        ]
        for config in configs {
            guard let base = try? stores.value(forKey: config.kvKey), !base.isEmpty,
                  base.hasPrefix("http") else { continue }
            let manifest = config.build(base)
            guard !homelabIDs.contains(manifest.id) else { continue }
            let connector = GenericHTTPConnector(manifest: manifest, keychain: keychain, stores: stores)
            await hub.register(connector)
            await connector.startTriggers()
            homelabIDs.append(manifest.id)
        }
    }

    // MARK: RAG sources (user-configured, D11)

    static let ragSourcesKey = "rag.sources"

    /// One user-added folder to index. Stored as JSON in the kv table —
    /// nothing is preconfigured (D18; also keeps personal paths out of code).
    struct RAGSourceConfig: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var path: String
    }

    private(set) var ragSourceConfigs: [RAGSourceConfig] = []

    private func loadRAGSourceConfigs() -> [RAGSourceConfig] {
        guard let raw = try? stores.value(forKey: Self.ragSourcesKey),
              let data = raw.data(using: .utf8),
              let configs = try? JSONDecoder().decode([RAGSourceConfig].self, from: data)
        else { return [] }
        return configs
    }

    private func persistRAGSourceConfigs() {
        guard let data = try? JSONEncoder().encode(ragSourceConfigs) else { return }
        try? stores.setValue(String(decoding: data, as: UTF8.self), forKey: Self.ragSourcesKey)
    }

    func addRAGSource(url: URL) {
        let path = url.standardizedFileURL.path
        guard !ragSourceConfigs.contains(where: { $0.path == path }) else { return }
        // Stable id derived from the path so reindexes stay attributable.
        let id = "src-" + String(path.hashValue.magnitude, radix: 36)
        ragSourceConfigs.append(RAGSourceConfig(id: id, name: url.lastPathComponent, path: path))
        persistRAGSourceConfigs()
        setupRAG()
        reindex()
    }

    func removeRAGSource(id: String) {
        guard let config = ragSourceConfigs.first(where: { $0.id == id }) else { return }
        ragSourceConfigs.removeAll { $0.id == id }
        persistRAGSourceConfigs()
        for doc in (try? stores.allDocuments(source: config.id)) ?? [] {
            try? stores.removeDocument(path: doc.path)
        }
        setupRAG()
        refreshIndexStats()
    }

    private func setupRAG() {
        ragSourceConfigs = loadRAGSourceConfigs()
        let fm = FileManager.default
        let sources: [IndexSource] = ragSourceConfigs.compactMap { config in
            guard fm.fileExists(atPath: config.path) else { return nil }
            return IndexSource(id: config.id, name: config.name,
                               url: URL(fileURLWithPath: config.path, isDirectory: true))
        }
        self.sources = sources

        let indexer = Indexer(stores: stores, embedder: embedder) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.indexProgressText = "\(progress.processed)/\(progress.total) · \(URL(fileURLWithPath: progress.currentPath).lastPathComponent)"
            }
        }
        self.indexer = indexer
        // Source changes at runtime must re-arm the folder watcher.
        if pumpTask != nil {
            let watched = sources
            Task { await indexer.startWatching(sources: watched) }
        }
        self.retriever = HybridRetriever(stores: stores, embedder: embedder, sources: sources)
        refreshIndexStats()
    }

    func reindex() {
        guard let indexer, !isIndexing else { return }
        isIndexing = true
        let sources = sources
        Task {
            defer { Task { @MainActor in self.isIndexing = false; self.refreshIndexStats() } }
            try? await indexer.fullScan(sources: sources)
            try? await indexer.embedMissing()
        }
    }

    func refreshIndexStats() {
        indexStats = (try? stores.chunkStats()) ?? (0, 0, 0)
    }

    // MARK: Event pipeline (D5)

    func startEventPump() async {
        guard pumpTask == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        await mail?.startPolling()
        await moodle?.startPolling()
        if let indexer {
            let sources = sources
            await indexer.startWatching(sources: sources)
        }

        let events = await hub.mergedEvents()
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: ConnectorEvent) async {
        guard let root = try? stores.record(ActivityEvent(
            kind: .eventReceived,
            connectorID: event.connectorID,
            summary: event.title,
            sourceID: event.sourceID)) else { return }

        // Light-model triage: urgent? actionable?
        let verdict = await triage(event)
        try? stores.record(ActivityEvent(
            kind: .classification,
            connectorID: event.connectorID,
            summary: "\(verdict.urgent ? "urgent" : "normal")\(verdict.actionable ? ", actionable" : ""): \(verdict.summary)",
            causedBy: root.id,
            sourceID: event.sourceID))

        // Local notifications for everything worth telling the user about,
        // routed through focus mode (urgent punches through, the rest
        // waits for a break). Telegram additionally covers "not at the Mac".
        if verdict.urgent {
            notifications?.deliver(
                title: event.title,
                body: verdict.summary,
                urgent: true)
            if Self.userIsAway() {
                await pushUrgent(event: event, summary: verdict.summary, causedBy: root.id)
            }
        } else if verdict.actionable || event.connectorID != "mail" {
            // Normal mail stays quiet (activity log only) — everything
            // else (deadlines, triggers) is a gentle update.
            notifications?.deliver(
                title: event.title,
                body: verdict.summary,
                urgent: false)
        }

        // Actionable mail → full agent turn; reversible actions happen
        // directly, risky ones become confirmation cards (D13).
        if verdict.actionable, event.connectorID == "mail", let agentLoop {
            let prompt = """
            New email arrived. Decide whether to create calendar entries or \
            reminders from it (only if clearly warranted), then summarize in \
            1-2 sentences what you did or suggest what the user should do.

            \(event.title)

            \(event.body)
            """
            let stream = await agentLoop.run(
                history: [], userMessage: prompt,
                causedBy: root.id, sourceID: event.sourceID)
            for await _ in stream {}   // outputs land in activity/suggestions
        }
        if event.connectorID == "mail" {
            // The companion scene drops an envelope on the desk.
            NotificationCenter.default.post(name: .aitvarasMailArrived, object: nil)
        }
        NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
    }

    private struct Triage {
        var urgent = false
        var actionable = false
        var summary = ""
    }

    private func triage(_ event: ConnectorEvent) async -> Triage {
        guard let engine = await router.engine(for: .background) else {
            return Triage(summary: event.title)
        }
        let messages = [
            ChatMessage(role: .system, content: """
                You triage incoming notifications for a personal assistant. \
                Reply ONLY with JSON: {"urgent": bool, "actionable": bool, "summary": "one sentence"}. \
                urgent = needs the user's attention within hours (deadlines today, \
                exam info, emergencies, direct personal requests, time-sensitive \
                social plans like a friend proposing lunch today). Newsletters and \
                automated mail are never urgent. actionable = contains a concrete \
                date, deadline or task worth putting in a calendar or todo list. \
                Reply with the JSON only, no deliberation. /no_think
                """),
            ChatMessage(role: .user, content: String("\(event.title)\n\n\(event.body)".prefix(4000)))
        ]
        var raw = ""
        do {
            for try await chunk in await engine.complete(messages: messages, tools: [], tier: .background) {
                if case .text(let t) = chunk { raw += t }
            }
        } catch {
            return Triage(summary: event.title)
        }
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Triage(summary: event.title)
        }
        return Triage(
            urgent: json["urgent"] as? Bool ?? false,
            actionable: json["actionable"] as? Bool ?? false,
            summary: json["summary"] as? String ?? event.title)
    }

    private func pushUrgent(event: ConnectorEvent, summary: String, causedBy: UUID) async {
        guard let telegram else { return }
        let text = "🔴 \(event.title)\n\(summary)"
        let args = ["text": text]
        guard let argsData = try? JSONSerialization.data(withJSONObject: args) else { return }
        do {
            _ = try await telegram.execute(
                toolName: "notify_phone",
                argumentsJSON: String(decoding: argsData, as: UTF8.self))
            try? stores.record(ActivityEvent(
                kind: .notificationSent,
                connectorID: "telegram",
                summary: "Urgent push: \(event.title)",
                causedBy: causedBy,
                sourceID: event.sourceID))
        } catch {
            // Telegram not configured — the classification entry already
            // records that this was urgent.
        }
    }

    /// "Send only when not active at the laptop" (D5): no input events
    /// for 5 minutes ≈ away.
    static func userIsAway() -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!)
        return idle > 300
    }
}

extension Notification.Name {
    static let aitvarasActivityChanged = Notification.Name("aitvarasActivityChanged")
    static let aitvarasShowCompanion = Notification.Name("aitvarasShowCompanion")
    static let aitvarasMailArrived = Notification.Name("aitvarasMailArrived")
}
