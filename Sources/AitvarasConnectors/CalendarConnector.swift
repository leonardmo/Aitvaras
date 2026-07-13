import EventKit
import Foundation
import AitvarasCore

/// Tagging scheme marking calendar events as Aitvaras-created (D6): every event
/// Aitvaras creates carry a URL with the `aitvaras://` scheme. Aitvaras may modify
/// or delete **only** events carrying this tag — everything else is the
/// user's data and is off-limits for writes.
public enum AitvarasEventTag {
    public static let scheme = "aitvaras"

    /// URL stored on Aitvaras-created events, e.g. `aitvaras://event/<uuid>`.
    public static func makeURL() -> URL {
        URL(string: "aitvaras://event/\(UUID().uuidString)")!
    }

    /// True when the event URL identifies the event as Aitvaras-managed.
    public static func isAitvarasManaged(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == scheme
    }
}

/// Apple Calendar via EventKit (D6). Creating events is a reversible write;
/// updating/deleting is allowed only for events Aitvaras created herself,
/// enforced here via `AitvarasEventTag` in addition to the central D13 policy.
public actor CalendarConnector: Connector {
    public nonisolated let id = "calendar"
    public nonisolated let displayName = "Calendar"

    /// Calendar and reminder-list name managed by Aitvaras, making her own
    /// entries easy to spot at a glance.
    public static let preferredContainerNames = ["Aitvaras"]
    public static var preferredContainerName: String { preferredContainerNames[0] }

    /// First calendar/list whose title matches a preferred name.
    public static func preferredMatch(_ title: String) -> Bool {
        preferredContainerNames.contains { title.caseInsensitiveCompare($0) == .orderedSame }
    }

    private let store = EKEventStore()

    public init() {}

    public nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "list_events",
            description: "List calendar events between two ISO-8601 timestamps. Optionally filter by calendar name. Returns one compact JSON object per line.",
            parametersJSON: """
            {"type":"object","properties":{"startISO":{"type":"string","description":"Range start, ISO-8601"},"endISO":{"type":"string","description":"Range end, ISO-8601"},"calendarName":{"type":"string","description":"Optional: only this calendar"}},"required":["startISO","endISO"]}
            """,
            risk: .read
        ),
        ToolDefinition(
            name: "create_event",
            description: "Create a calendar event. The event is tagged as Aitvaras-created so it can be modified or deleted later.",
            parametersJSON: """
            {"type":"object","properties":{"title":{"type":"string"},"startISO":{"type":"string","description":"Start, ISO-8601"},"endISO":{"type":"string","description":"End, ISO-8601"},"notes":{"type":"string"},"calendarName":{"type":"string","description":"Optional: target calendar; default calendar if omitted"}},"required":["title","startISO","endISO"]}
            """,
            risk: .reversibleWrite
        ),
        ToolDefinition(
            name: "update_event",
            description: "Update an event previously created by Aitvaras (identified by eventID from list_events/create_event). Refuses to touch events Aitvaras did not create.",
            parametersJSON: """
            {"type":"object","properties":{"eventID":{"type":"string"},"title":{"type":"string"},"startISO":{"type":"string"},"endISO":{"type":"string"},"notes":{"type":"string"}},"required":["eventID"]}
            """,
            risk: .reversibleWrite
        ),
        ToolDefinition(
            name: "delete_event",
            description: "Delete an event previously created by Aitvaras. Refuses to delete events Aitvaras did not create.",
            parametersJSON: """
            {"type":"object","properties":{"eventID":{"type":"string"}},"required":["eventID"]}
            """,
            risk: .reversibleWrite
        )
    ]

    public func health() async -> ConnectorHealth {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .ready
        case .notDetermined:
            return .needsAuthentication(message: "Calendar access not requested yet — Aitvaras will ask on first use.")
        case .writeOnly:
            return .needsAuthentication(message: "Only write access to Calendar was granted. Grant full access in System Settings → Privacy & Security → Calendars.")
        case .denied, .restricted:
            return .needsAuthentication(message: "Calendar access is denied. Enable it in System Settings → Privacy & Security → Calendars.")
        @unknown default:
            return .error(message: "Unknown Calendar authorization status.")
        }
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        let args = try ToolArgs(json: argumentsJSON)
        try await ensureFullAccess()

        switch toolName {
        case "list_events":
            return try listEvents(args)
        case "create_event":
            return try createEvent(args)
        case "update_event":
            return try updateEvent(args)
        case "delete_event":
            return try deleteEvent(args)
        default:
            throw ConnectorError("Calendar connector has no tool named '\(toolName)'.")
        }
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        AsyncStream { $0.finish() }   // pull-only connector
    }

    // MARK: - Tools

    private func listEvents(_ args: ToolArgs) throws -> String {
        let start = try ISO.requireDate(args.requiredString("startISO"), argument: "startISO")
        let end = try ISO.requireDate(args.requiredString("endISO"), argument: "endISO")
        guard end > start else { throw ConnectorError("endISO must be after startISO.") }

        let calendars = try resolveCalendars(named: args.string("calendarName"))
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        let capped = events.prefix(150)
        let lines = capped.map { event in
            JSONText.object([
                ("id", .string(event.eventIdentifier ?? "")),
                ("title", .string(event.title ?? "")),
                ("start", .string(ISO.string(from: event.startDate))),
                ("end", .string(ISO.string(from: event.endDate))),
                ("allDay", event.isAllDay ? .bool(true) : nil),
                ("calendar", .string(event.calendar?.title ?? "")),
                ("location", event.location.map { .string($0) }),
                ("aitvarasCreated", AitvarasEventTag.isAitvarasManaged(event.url) ? .bool(true) : nil)
            ])
        }
        var result = lines.joined(separator: "\n")
        if events.count > capped.count {
            result += "\n…[\(events.count - capped.count) more events omitted]"
        }
        return result.isEmpty ? "No events in this range." : result
    }

    private func createEvent(_ args: ToolArgs) throws -> String {
        let event = EKEvent(eventStore: store)
        event.title = try args.requiredString("title")
        event.startDate = try ISO.requireDate(args.requiredString("startISO"), argument: "startISO")
        event.endDate = try ISO.requireDate(args.requiredString("endISO"), argument: "endISO")
        guard event.endDate > event.startDate else { throw ConnectorError("endISO must be after startISO.") }
        event.notes = args.string("notes")
        // Tag as Aitvaras-created (D6) — invisible to the user, checked on update/delete.
        event.url = AitvarasEventTag.makeURL()

        if let name = args.string("calendarName") {
            guard let calendar = try resolveCalendars(named: name)?.first else {
                throw ConnectorError("No calendar named '\(name)'.")
            }
            event.calendar = calendar
        } else if let ownCalendar = store.calendars(for: .event).first(where: {
            Self.preferredMatch($0.title)
        }) {
            event.calendar = ownCalendar
        } else {
            guard let calendar = store.defaultCalendarForNewEvents else {
                throw ConnectorError("No default calendar available.")
            }
            event.calendar = calendar
        }

        try store.save(event, span: .thisEvent, commit: true)
        return JSONText.object([
            ("id", .string(event.eventIdentifier ?? "")),
            ("title", .string(event.title ?? "")),
            ("start", .string(ISO.string(from: event.startDate))),
            ("end", .string(ISO.string(from: event.endDate))),
            ("calendar", .string(event.calendar?.title ?? ""))
        ])
    }

    private func updateEvent(_ args: ToolArgs) throws -> String {
        let event = try aitvarasOwnedEvent(id: args.requiredString("eventID"), action: "modify")

        if let title = args.string("title") { event.title = title }
        if let s = args.string("startISO") { event.startDate = try ISO.requireDate(s, argument: "startISO") }
        if let e = args.string("endISO") { event.endDate = try ISO.requireDate(e, argument: "endISO") }
        if let notes = args.string("notes") { event.notes = notes }
        guard event.endDate > event.startDate else { throw ConnectorError("Event end must be after start.") }

        try store.save(event, span: .thisEvent, commit: true)
        return "Updated event '\(event.title ?? "")' (\(ISO.string(from: event.startDate)) – \(ISO.string(from: event.endDate)))."
    }

    private func deleteEvent(_ args: ToolArgs) throws -> String {
        let event = try aitvarasOwnedEvent(id: args.requiredString("eventID"), action: "delete")
        let title = event.title ?? ""
        try store.remove(event, span: .thisEvent, commit: true)
        return "Deleted Aitvaras-created event '\(title)'."
    }

    // MARK: - Helpers

    /// Fetch an event and enforce D6: only Aitvaras-created (aitvaras:// tagged)
    /// events may be modified or deleted.
    private func aitvarasOwnedEvent(id: String, action: String) throws -> EKEvent {
        guard let event = store.event(withIdentifier: id) else {
            throw ConnectorError("No event with id '\(id)'.")
        }
        guard AitvarasEventTag.isAitvarasManaged(event.url) else {
            throw ConnectorError(
                "Refusing to \(action) '\(event.title ?? id)': Aitvaras only modifies events she created herself (D6). Ask the user to change it, or create a new event instead.")
        }
        return event
    }

    private func resolveCalendars(named name: String?) throws -> [EKCalendar]? {
        guard let name else { return nil }
        let matches = store.calendars(for: .event).filter { $0.title == name }
        guard !matches.isEmpty else {
            let available = store.calendars(for: .event).map(\.title).joined(separator: ", ")
            throw ConnectorError("No calendar named '\(name)'. Available: \(available)")
        }
        return matches
    }

    private func ensureFullAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                store.requestFullAccessToEvents { granted, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: granted) }
                }
            }
            guard granted else { throw ConnectorError("Calendar access was not granted.") }
        default:
            throw ConnectorError("Calendar access is denied. Enable it in System Settings → Privacy & Security → Calendars.")
        }
    }
}
