import Foundation
import AitvarasCore
import AitvarasStore

/// Reads the user's Notification Center via the sandboxed notify-reader
/// helper (D21): WhatsApp/Signal/anything lands in the triage pipeline —
/// urgent things punch through focus mode. Aitvaras's own process never
/// holds Full Disk Access; the helper is spawned with the TCC "disclaim"
/// attribute so the permission check targets the helper binary alone.
actor NotificationsConnector: Connector {
    nonisolated let id = "notifications"
    nonisolated let displayName = "System Notifications"

    private let stores: Stores
    private var pollTask: Task<Void, Never>?
    private var eventContinuations: [UUID: AsyncStream<ConnectorEvent>.Continuation] = [:]

    /// Apps whose notifications are never interesting to triage.
    private static let ignoredApps: Set<String> = [
        "app.aitvaras.Aitvaras", "com.apple.Spotlight", "com.apple.systempreferences"
    ]

    init(stores: Stores) {
        self.stores = stores
    }

    nonisolated static var helperURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("notify-reader")
    }

    nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "recent_notifications",
            description: "The user's recent macOS notifications from all apps (WhatsApp, Signal, etc.): app, time, title, message.",
            parametersJSON: #"{"type":"object","properties":{"minutes":{"type":"integer","description":"Look-back window, default 60, max 720"}},"required":[]}"#,
            risk: .read)
    ]

    func health() async -> ConnectorHealth {
        guard let helper = Self.helperURL,
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            return .error(message: "notify-reader helper missing from app bundle")
        }
        do {
            _ = try await runHelper(since: Date.now.timeIntervalSince1970 - 60)
            return .ready
        } catch {
            return .needsAuthentication(message:
                "Grant Full Disk Access to notify-reader (not to Aitvaras): System Settings → Privacy & Security → Full Disk Access → + → press ⌘⇧G and paste the helper path from the Connections tab.")
        }
    }

    func execute(toolName: String, argumentsJSON: String) async throws -> String {
        guard toolName == "recent_notifications" else {
            throw NSError(domain: "notifications", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown tool \(toolName)"])
        }
        var minutes = 60
        if let data = argumentsJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = json["minutes"] as? Int {
            minutes = min(max(m, 1), 720)
        }
        let items = try await runHelper(since: Date.now.timeIntervalSince1970 - Double(minutes * 60))
        if items.isEmpty { return "No notifications in the last \(minutes) minutes." }
        return items.suffix(40).map(\.line).joined(separator: "\n")
    }

    // MARK: Polling → events

    func startPolling(interval: TimeInterval = 45) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        let watermarkKey = "notifications.watermark"
        let since = Double((try? stores.value(forKey: watermarkKey)) ?? nil ?? "")
            ?? Date.now.timeIntervalSince1970 - 300
        guard let items = try? await runHelper(since: since) else { return }
        var newest = since
        for item in items {
            newest = max(newest, item.deliveredAt)
            guard !Self.ignoredApps.contains(item.app) else { continue }
            let itemID = "\(item.app)-\(item.deliveredAt)-\(item.title.hashValue)"
            guard (try? stores.markSeen(connectorID: id, itemID: itemID)) == true else { continue }
            let event = ConnectorEvent(
                connectorID: id,
                sourceID: itemID,
                title: "\(Self.friendlyAppName(item.app)): \(item.title)",
                body: [item.subtitle, item.body].filter { !$0.isEmpty }.joined(separator: "\n"),
                occurredAt: Date(timeIntervalSince1970: item.deliveredAt))
            for continuation in eventContinuations.values {
                continuation.yield(event)
            }
        }
        try? stores.setValue(String(newest), forKey: watermarkKey)
    }

    nonisolated static func friendlyAppName(_ bundleID: String) -> String {
        let known: [String: String] = [
            "net.whatsapp.WhatsApp": "WhatsApp",
            "com.apple.MobileSMS": "Messages",
            "org.whispersystems.signal-desktop": "Signal",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.hnc.Discord": "Discord",
            "com.apple.mail": "Mail",
            "ru.keepcoder.Telegram": "Telegram"
        ]
        return known[bundleID] ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    func events() -> AsyncStream<ConnectorEvent> {
        AsyncStream { continuation in
            let key = UUID()
            eventContinuations[key] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(key) }
            }
        }
    }

    private func removeContinuation(_ key: UUID) {
        eventContinuations[key] = nil
    }

    // MARK: Helper process

    struct Item {
        let app: String
        let deliveredAt: Double
        let title: String
        let subtitle: String
        let body: String

        var line: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let time = formatter.string(from: Date(timeIntervalSince1970: deliveredAt))
            return "[\(time)] \(NotificationsConnector.friendlyAppName(app)) — \(title)\(subtitle.isEmpty ? "" : " · \(subtitle)"): \(body)"
        }
    }

    private func runHelper(since: Double) async throws -> [Item] {
        guard let helper = Self.helperURL else {
            throw NSError(domain: "notifications", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "helper missing"])
        }
        let output = try await DisclaimedProcess.run(
            executable: helper.path,
            arguments: ["--since", String(since)],
            timeout: 20)
        guard output.exitCode == 0 else {
            throw NSError(domain: "notifications", code: Int(output.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: "helper exited \(output.exitCode)"])
        }
        return output.stdout.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let app = json["app"] as? String,
                  let delivered = json["deliveredAt"] as? Double else { return nil }
            return Item(
                app: app,
                deliveredAt: delivered,
                title: json["title"] as? String ?? "",
                subtitle: json["subtitle"] as? String ?? "",
                body: json["body"] as? String ?? "")
        }
    }
}
