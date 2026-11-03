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
    private let reporter: ActivityReporter?
    private var pollingInterval: TimeInterval = 45
    private var pollTask: Task<Void, Never>?
    private var lastPollingError: String?
    private var eventContinuations: [UUID: AsyncStream<ConnectorEvent>.Continuation] = [:]

    /// Apps whose notifications are never interesting to triage.
    private static let ignoredApps: Set<String> = [
        "app.aitvaras.Aitvaras", "com.apple.Spotlight", "com.apple.systempreferences"
    ]

    init(stores: Stores, reporter: ActivityReporter? = nil) {
        self.stores = stores
        self.reporter = reporter
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
            if let lastPollingError {
                return .error(message: "Notification polling failed: \(lastPollingError)")
            }
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
        guard pollTask == nil, automaticChecksAllowed else { return }
        pollingInterval = max(5, interval)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(trigger: .automatic)
                do { try await Task.sleep(for: .seconds(max(5, interval))) }
                catch { return }
            }
        }
    }

    func stopPolling() async {
        let previous = pollTask
        previous?.cancel()
        pollTask = nil
        await previous?.value
        reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
            enabled: false, paused: true, stage: "Automatic notification checks paused"))
    }

    /// Read notifications delivered while macOS was asleep. Central intake
    /// still owns trust checks, durable deduplication, and the watermark.
    func wakeCatchUpEvents(
        since: Date,
        excludingApplicationIDs: Set<String> = [],
        trigger: ActivityTrigger = ActivityTaskContext.trigger
    ) async throws -> (events: [ConnectorEvent], wasLimited: Bool) {
        guard pollAllowed(trigger) else { return ([], false) }
        reportPollStart()
        guard pollAllowed(trigger) else { return ([], false) }
        do {
            let items = try await runHelper(since: since.timeIntervalSince1970)
            guard pollAllowed(trigger) else { return ([], false) }
            lastPollingError = nil
            reportPollResult(succeeded: true)
            let relevant = items
                .filter {
                    !Self.ignoredApps.contains($0.app)
                        && !excludingApplicationIDs.contains($0.app)
                }
                .sorted { $0.deliveredAt > $1.deliveredAt }
            let selected = ConnectorEventStreams.boundedWakeCatchUp(relevant)
            return (
                events: selected.items.map(event(for:)),
                wasLimited: selected.wasLimited)
        } catch {
            if pollAllowed(trigger) {
                lastPollingError = error.localizedDescription
                reportPollResult(succeeded: false)
            }
            throw error
        }
    }

    private func pollOnce(trigger: ActivityTrigger = .manual) async {
        guard pollAllowed(trigger) else { return }
        reportPollStart()
        guard pollAllowed(trigger) else { return }
        let watermarkKey = "notifications.watermark"
        let since: Double
        do {
            since = Double(try stores.value(forKey: watermarkKey) ?? "")
                ?? Date.now.timeIntervalSince1970 - 300
        } catch {
            lastPollingError = error.localizedDescription
            reportPollResult(succeeded: false)
            return
        }
        let items: [Item]
        do {
            items = try await runHelper(since: since)
            guard pollAllowed(trigger) else { return }
        } catch {
            if pollAllowed(trigger) {
                lastPollingError = error.localizedDescription
                reportPollResult(succeeded: false)
            }
            return
        }
        var newest = since
        var emittedRelevantItem = false
        for item in items {
            guard pollAllowed(trigger) else { return }
            newest = max(newest, item.deliveredAt)
            guard !Self.ignoredApps.contains(item.app) else { continue }
            emittedRelevantItem = true
            let event = event(for: item)
            for continuation in eventContinuations.values {
                continuation.yield(event)
            }
        }
        // Relevant events advance the watermark only when central intake
        // commits them. If this batch contained only ignored apps there is
        // nothing to lose, so advancing here avoids refetching them forever.
        if !emittedRelevantItem {
            do {
                try stores.setValue(String(newest), forKey: watermarkKey)
            } catch {
                lastPollingError = error.localizedDescription
                reportPollResult(succeeded: false)
                return
            }
        }
        lastPollingError = nil
        reportPollResult(succeeded: true)
    }

    private var automaticChecksAllowed: Bool {
        reporter?.failureMessage == nil
            && (try? stores.backgroundWorkPolicy().permits(.notifications, trigger: .automatic)) == true
    }

    private func pollAllowed(_ trigger: ActivityTrigger) -> Bool {
        guard !Task.isCancelled else { return false }
        guard trigger != .manual else { return true }
        let allowed = automaticChecksAllowed
        if !allowed {
            reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
                enabled: false, paused: true, stage: "Automatic notification checks not permitted"))
        }
        return allowed
    }

    private func reportPollStart() {
        let enabled = automaticChecksAllowed
        reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
            enabled: enabled, paused: !enabled,
            stage: "Checking notifications", lastAttempt: .now,
            problem: lastPollingError == nil ? nil : "The previous notification check failed; retrying."))
    }

    private func reportPollResult(succeeded: Bool) {
        let now = Date.now
        let enabled = automaticChecksAllowed
        reporter?.serviceCheck(id: id, succeeded: succeeded, at: now)
        reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
            enabled: enabled, paused: !enabled,
            stage: succeeded ? "Waiting for next check" : "Notification check failed",
            lastAttempt: now, lastSuccess: succeeded ? now : nil,
            nextOpportunity: enabled ? now.addingTimeInterval(pollingInterval) : nil,
            problem: succeeded ? nil : "Notifications could not be checked. Review helper availability and permissions."))
    }

    private func event(for item: Item) -> ConnectorEvent {
        // `hashValue` changes on every process launch. A deterministic,
        // one-way id prevents the same notification being triaged again
        // after restart without persisting its title in the seen table.
        let itemID = StableIdentifier.short([
            item.app, String(item.deliveredAt), item.title, item.subtitle, item.body
        ])
        let applicationName = Self.friendlyAppName(item.app)
        // Notification Center does not expose a verified contact id. The
        // visible sender label is therefore scoped to the exact app and
        // remains explicitly unverified in the trust UI.
        let senderLabel = item.title.isEmpty ? item.subtitle : item.title
        return ConnectorEvent(
            connectorID: id,
            sourceID: itemID,
            title: "\(applicationName): \(item.title)",
            body: [item.subtitle, item.body].filter { !$0.isEmpty }.joined(separator: "\n"),
            occurredAt: Date(timeIntervalSince1970: item.deliveredAt),
            externalMessageSource: .notification(
                applicationID: item.app,
                applicationName: applicationName,
                senderLabel: senderLabel))
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
        let pair = ConnectorEventStreams.make()
        let key = UUID()
        eventContinuations[key] = pair.continuation
        pair.continuation.onTermination = { _ in
            Task { await self.removeContinuation(key) }
        }
        return pair.stream
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
