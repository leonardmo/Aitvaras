import Foundation
import AitvarasCore
import AitvarasStore

/// Moodle via the iCal calendar-export URL — D9 phase 1 (works with any
/// Moodle that has calendar export enabled, e.g. moodle.example.edu).
/// The mobile web service is disabled at many universities, but the calendar export gives
/// assignment deadlines and course events through a permanent-ish URL.
///
/// The export URL embeds its auth token, so the WHOLE URL is a secret and
/// lives in the Keychain under "moodle.icalURL" — never in the kv store.
public actor MoodleConnector: Connector {
    public nonisolated let id = "moodle"
    public nonisolated let displayName = "Moodle"

    public static let icalURLKeychainKey = "moodle.icalURL"
    static let responseByteLimit = 5 * 1024 * 1024

    private let keychain: KeychainStore
    private let stores: Stores
    private let session: URLSession
    private let reporter: ActivityReporter?
    private var pollingInterval: TimeInterval = 24 * 60 * 60

    private let eventStream: AsyncStream<ConnectorEvent>
    private let eventContinuation: AsyncStream<ConnectorEvent>.Continuation
    private var pollTask: Task<Void, Never>?
    private var lastPollingError: String?

    public init(keychain: KeychainStore, stores: Stores,
                session: URLSession = ConnectorHTTPSession.make(), reporter: ActivityReporter? = nil) {
        self.keychain = keychain
        self.stores = stores
        self.session = session
        self.reporter = reporter
        (self.eventStream, self.eventContinuation) = ConnectorEventStreams.make()
    }

    deinit {
        pollTask?.cancel()
        eventContinuation.finish()
    }

    public nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "upcoming_deadlines",
            description: "Upcoming Moodle deadlines and course events within the next N days (default 14). Returns one compact JSON object per line, soonest first.",
            parametersJSON: """
            {"type":"object","properties":{"days":{"type":"integer","description":"Look-ahead window in days (default 14)"}},"required":[]}
            """,
            risk: .read
        )
    ]

    public func health() async -> ConnectorHealth {
        do {
            guard let url = try keychain.get(Self.icalURLKeychainKey),
                  URL(string: url) != nil else {
                return .needsAuthentication(message: "No Moodle calendar URL. In Moodle: Preferences → Calendar → Export calendar, then paste the URL in Settings → Connectors → Moodle.")
            }
        } catch {
            return .error(message: "Moodle settings could not be checked: \(error.localizedDescription)")
        }
        if let lastPollingError {
            return .error(message: "Calendar polling failed: \(lastPollingError)")
        }
        return .ready
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        guard toolName == "upcoming_deadlines" else {
            throw ConnectorError("Moodle connector has no tool named '\(toolName)'.")
        }
        let args = try ToolArgs(json: argumentsJSON)
        let days = min(max(args.int("days") ?? 14, 1), 90)

        let events = try await upcomingEvents(withinDays: days)
        guard !events.isEmpty else { return "No Moodle deadlines within the next \(days) days." }
        return events.map { event in
            JSONText.object([
                ("uid", .string(event.uid)),
                ("title", .string(event.summary)),
                ("due", event.start.map { .string(ISO.string(from: $0)) }),
                ("allDay", event.isAllDay ? .bool(true) : nil),
                ("course", event.categories.isEmpty ? nil : .string(event.categories.joined(separator: ", "))),
                ("description", event.description.isEmpty ? nil : .string(String(event.description.prefix(300))))
            ])
        }.joined(separator: "\n")
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        eventStream
    }

    /// Begin the daily deadline check. Called by the app; new UIDs due within
    /// the next 14 days surface as ConnectorEvents (markSeen dedup).
    public func startPolling(interval: TimeInterval = 24 * 60 * 60) {
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

    public func stopPolling() async {
        let previous = pollTask
        previous?.cancel()
        pollTask = nil
        await previous?.value
        reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
            enabled: false, paused: true, stage: "Automatic calendar checks paused"))
    }

    /// Refresh upcoming course events immediately after wake rather than
    /// waiting for the daily poll. Stable UIDs make replay through central
    /// intake harmless.
    public func wakeCatchUpEvents(trigger: ActivityTrigger = ActivityTaskContext.trigger) async throws
        -> (events: [ConnectorEvent], wasLimited: Bool) {
        guard pollAllowed(trigger) else { return ([], false) }
        reportPollStart()
        guard pollAllowed(trigger) else { return ([], false) }
        do {
            let events = try await upcomingEvents(withinDays: 14)
            guard pollAllowed(trigger) else { return ([], false) }
            lastPollingError = nil
            reportPollResult(succeeded: true)
            let selected = ConnectorEventStreams.boundedWakeCatchUp(events)
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

    // MARK: - Private

    private func pollOnce(trigger: ActivityTrigger = .manual) async {
        guard pollAllowed(trigger) else { return }
        reportPollStart()
        guard pollAllowed(trigger) else { return }
        let events: [ICS.Event]
        do {
            events = try await upcomingEvents(withinDays: 14)
            guard pollAllowed(trigger) else { return }
            lastPollingError = nil
        } catch {
            if pollAllowed(trigger) {
                lastPollingError = error.localizedDescription
                reportPollResult(succeeded: false)
            }
            return
        }
        reportPollResult(succeeded: true)
        for event in events {
            guard pollAllowed(trigger) else { return }
            eventContinuation.yield(self.event(for: event))
        }
    }

    private func pollAllowed(_ trigger: ActivityTrigger) -> Bool {
        guard !Task.isCancelled else { return false }
        guard trigger != .manual else { return true }
        let allowed = automaticChecksAllowed
        if !allowed {
            reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
                enabled: false, paused: true, stage: "Automatic calendar checks not permitted"))
        }
        return allowed
    }

    private var automaticChecksAllowed: Bool {
        reporter?.failureMessage == nil
            && (try? stores.backgroundWorkPolicy().permits(.connectors, trigger: .automatic)) == true
    }

    private func reportPollStart() {
        let enabled = automaticChecksAllowed
        reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
            enabled: enabled, paused: !enabled,
            stage: "Checking calendar", lastAttempt: .now,
            problem: lastPollingError == nil ? nil : "The previous calendar check failed; retrying."))
    }

    private func reportPollResult(succeeded: Bool) {
        let now = Date.now
        let enabled = automaticChecksAllowed
        reporter?.serviceCheck(id: id, succeeded: succeeded, at: now)
        reporter?.service(ServiceStatus(id: id, name: displayName, configured: true,
            enabled: enabled, paused: !enabled,
            stage: succeeded ? "Waiting for next check" : "Calendar check failed",
            lastAttempt: now, lastSuccess: succeeded ? now : nil,
            nextOpportunity: enabled ? now.addingTimeInterval(pollingInterval) : nil,
            problem: succeeded ? nil : "Calendar could not be checked. Review the configured connection."))
    }

    private func event(for event: ICS.Event) -> ConnectorEvent {
        let due = event.start.map { ISO.string(from: $0) } ?? "unknown date"
        let course = event.categories.joined(separator: ", ")
        return ConnectorEvent(
            connectorID: id,
            sourceID: "moodle:\(event.uid)",
            title: "Moodle deadline: \(event.summary)",
            body: "Due \(due)\(course.isEmpty ? "" : " · \(course)")\n\(String(event.description.prefix(500)))",
            occurredAt: .now,
            externalMessageSource: .configuredService(
                id: id, displayName: displayName))
    }

    private func upcomingEvents(withinDays days: Int) async throws -> [ICS.Event] {
        guard let urlString = try keychain.get(Self.icalURLKeychainKey),
              let url = URL(string: urlString) else {
            throw ConnectorError("Moodle calendar URL missing — paste the calendar-export URL in Settings first.")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedHTTP.data(
                from: url, using: session,
                maximumBytes: Self.responseByteLimit)
        } catch {
            throw ConnectorDiagnostics.networkFailure(
                operation: "Moodle calendar request", error: error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ConnectorError("Moodle calendar export returned HTTP \(http.statusCode) — the export URL may have been revoked; generate a new one in Moodle.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectorError("Moodle calendar export is not readable text.")
        }
        let sensitiveNames = ["token", "key", "auth", "secret", "password", "pass"]
        let querySecrets = URLComponents(
            url: url, resolvingAgainstBaseURL: false)?.queryItems?.compactMap { item in
                sensitiveNames.contains(where: { item.name.lowercased().contains($0) })
                    ? item.value : nil
            } ?? []
        let urlSecrets = [urlString] + querySecrets
        let safeText = ConnectorDiagnostics.redacted(text, secrets: urlSecrets)

        let now = Date.now
        let horizon = now.addingTimeInterval(TimeInterval(days) * 24 * 60 * 60)
        return ICS.parse(safeText)
            .filter { event in
                guard let start = event.start else { return false }
                return start >= now && start <= horizon
            }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }
}
