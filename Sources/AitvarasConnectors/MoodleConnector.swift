import Foundation
import AitvarasCore
import AitvarasStore

/// Moodle via the iCal calendar-export URL — D9 phase 1 (works with any
/// Moodle that has calendar export enabled, e.g. moodle.tum.de).
/// The mobile web service is disabled at TUM, but the calendar export gives
/// assignment deadlines and course events through a permanent-ish URL.
///
/// The export URL embeds its auth token, so the WHOLE URL is a secret and
/// lives in the Keychain under "moodle.icalURL" — never in the kv store.
public actor MoodleConnector: Connector {
    public nonisolated let id = "moodle"
    public nonisolated let displayName = "Moodle"

    public static let icalURLKeychainKey = "moodle.icalURL"

    private let keychain: KeychainStore
    private let stores: Stores
    private let session: URLSession

    private let eventStream: AsyncStream<ConnectorEvent>
    private let eventContinuation: AsyncStream<ConnectorEvent>.Continuation
    private var pollTask: Task<Void, Never>?

    public init(keychain: KeychainStore, stores: Stores, session: URLSession = .shared) {
        self.keychain = keychain
        self.stores = stores
        self.session = session
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: ConnectorEvent.self)
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
        guard let url = try? keychain.get(Self.icalURLKeychainKey), URL(string: url) != nil else {
            return .needsAuthentication(message: "No Moodle calendar URL. In Moodle: Preferences → Calendar → Export calendar, then paste the URL in Settings → Connectors → Moodle.")
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
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private

    private func pollOnce() async {
        guard let events = try? await upcomingEvents(withinDays: 14) else { return }
        for event in events {
            guard (try? stores.markSeen(connectorID: id, itemID: event.uid)) == true else { continue }
            let due = event.start.map { ISO.string(from: $0) } ?? "unknown date"
            let course = event.categories.joined(separator: ", ")
            eventContinuation.yield(ConnectorEvent(
                connectorID: id,
                sourceID: "moodle:\(event.uid)",
                title: "Moodle deadline: \(event.summary)",
                body: "Due \(due)\(course.isEmpty ? "" : " · \(course)")\n\(String(event.description.prefix(500)))",
                occurredAt: .now))
        }
    }

    private func upcomingEvents(withinDays days: Int) async throws -> [ICS.Event] {
        guard let urlString = try? keychain.get(Self.icalURLKeychainKey),
              let url = URL(string: urlString) else {
            throw ConnectorError("Moodle calendar URL missing — paste the calendar-export URL in Settings first.")
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ConnectorError("Moodle calendar export returned HTTP \(http.statusCode) — the export URL may have been revoked; generate a new one in Moodle.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectorError("Moodle calendar export is not readable text.")
        }

        let now = Date.now
        let horizon = now.addingTimeInterval(TimeInterval(days) * 24 * 60 * 60)
        return ICS.parse(text)
            .filter { event in
                guard let start = event.start else { return false }
                return start >= now && start <= horizon
            }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }
}
