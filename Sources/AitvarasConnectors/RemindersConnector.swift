import EventKit
import Foundation
import AitvarasCore

/// Apple Reminders via EventKit (D7) — the user's task system after the
/// migration away from Microsoft To Do. Creating and completing reminders
/// are reversible writes under D13.
public actor RemindersConnector: Connector {
    public nonisolated let id = "reminders"
    public nonisolated let displayName = "Reminders"

    private let store = EKEventStore()

    public init() {}

    public nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "list_reminders",
            description: "List reminders, optionally from a single list. Incomplete only unless includeCompleted is true. Returns one compact JSON object per line.",
            parametersJSON: """
            {"type":"object","properties":{"listName":{"type":"string","description":"Optional: only this reminders list"},"includeCompleted":{"type":"boolean","description":"Include completed reminders (default false)"}},"required":[]}
            """,
            risk: .read
        ),
        ToolDefinition(
            name: "create_reminder",
            description: "Create a reminder, optionally with a due date and in a specific list.",
            parametersJSON: """
            {"type":"object","properties":{"title":{"type":"string"},"dueISO":{"type":"string","description":"Optional due date/time, ISO-8601"},"notes":{"type":"string"},"listName":{"type":"string","description":"Optional: target list; default list if omitted"}},"required":["title"]}
            """,
            risk: .reversibleWrite
        ),
        ToolDefinition(
            name: "complete_reminder",
            description: "Mark a reminder as completed (reminderID from list_reminders/create_reminder).",
            parametersJSON: """
            {"type":"object","properties":{"reminderID":{"type":"string"}},"required":["reminderID"]}
            """,
            risk: .reversibleWrite
        )
    ]

    public func health() async -> ConnectorHealth {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return .ready
        case .notDetermined:
            return .needsAuthentication(message: "Reminders access not requested yet — Aitvaras will ask on first use.")
        case .writeOnly:
            return .needsAuthentication(message: "Only write access to Reminders was granted. Grant full access in System Settings → Privacy & Security → Reminders.")
        case .denied, .restricted:
            return .needsAuthentication(message: "Reminders access is denied. Enable it in System Settings → Privacy & Security → Reminders.")
        @unknown default:
            return .error(message: "Unknown Reminders authorization status.")
        }
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        let args = try ToolArgs(json: argumentsJSON)
        try await ensureFullAccess()

        switch toolName {
        case "list_reminders":
            return try await listReminders(args)
        case "create_reminder":
            return try createReminder(args)
        case "complete_reminder":
            return try completeReminder(args)
        default:
            throw ConnectorError("Reminders connector has no tool named '\(toolName)'.")
        }
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        AsyncStream { $0.finish() }   // pull-only connector
    }

    // MARK: - Tools

    private func listReminders(_ args: ToolArgs) async throws -> String {
        let includeCompleted = args.bool("includeCompleted") ?? false
        let calendars = try resolveLists(named: args.string("listName"))
        let predicate = store.predicateForReminders(in: calendars)

        let reminders = await fetchReminders(matching: predicate)
        let filtered = reminders
            .filter { includeCompleted || !$0.isCompleted }
            .sorted { lhs, rhs in
                let l = lhs.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                let r = rhs.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                return l < r
            }

        let capped = filtered.prefix(150)
        let lines = capped.map { reminder in
            let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            return JSONText.object([
                ("id", .string(reminder.calendarItemIdentifier)),
                ("title", .string(reminder.title ?? "")),
                ("due", due.map { .string(ISO.string(from: $0)) }),
                ("list", .string(reminder.calendar?.title ?? "")),
                ("completed", reminder.isCompleted ? .bool(true) : nil),
                ("notes", reminder.notes.map { .string(String($0.prefix(200))) })
            ])
        }
        var result = lines.joined(separator: "\n")
        if filtered.count > capped.count {
            result += "\n…[\(filtered.count - capped.count) more reminders omitted]"
        }
        return result.isEmpty ? "No matching reminders." : result
    }

    private func createReminder(_ args: ToolArgs) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = try args.requiredString("title")
        reminder.notes = args.string("notes")

        if let dueISO = args.string("dueISO") {
            let due = try ISO.requireDate(dueISO, argument: "dueISO")
            // Date-only strings become all-day due dates (no hour/minute).
            let isDateOnly = !dueISO.contains("T")
            let components: Set<Calendar.Component> = isDateOnly
                ? [.year, .month, .day]
                : [.year, .month, .day, .hour, .minute]
            reminder.dueDateComponents = Calendar.current.dateComponents(components, from: due)
        }

        if let name = args.string("listName") {
            guard let list = try resolveLists(named: name)?.first else {
                throw ConnectorError("No reminders list named '\(name)'.")
            }
            reminder.calendar = list
        } else if let ownList = store.calendars(for: .reminder).first(where: {
            CalendarConnector.preferredMatch($0.title)
        }) {
            // Same convention as events: her todos land in the "Aitvaras" list.
            reminder.calendar = ownList
        } else {
            guard let list = store.defaultCalendarForNewReminders() else {
                throw ConnectorError("No default reminders list available.")
            }
            reminder.calendar = list
        }

        try store.save(reminder, commit: true)
        return JSONText.object([
            ("id", .string(reminder.calendarItemIdentifier)),
            ("title", .string(reminder.title ?? "")),
            ("list", .string(reminder.calendar?.title ?? ""))
        ])
    }

    private func completeReminder(_ args: ToolArgs) throws -> String {
        let id = try args.requiredString("reminderID")
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ConnectorError("No reminder with id '\(id)'.")
        }
        guard !reminder.isCompleted else {
            return "Reminder '\(reminder.title ?? id)' was already completed."
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        return "Completed reminder '\(reminder.title ?? id)'."
    }

    // MARK: - Helpers

    /// EKReminder is not Sendable; the batch crosses from EventKit's
    /// delivery queue back into this actor, which is the only consumer —
    /// the box takes the @unchecked responsibility for that handoff.
    private struct ReminderBatch: @unchecked Sendable {
        let reminders: [EKReminder]
    }

    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        let batch = await withCheckedContinuation { (cont: CheckedContinuation<ReminderBatch, Never>) in
            store.fetchReminders(matching: predicate) { reminders in
                cont.resume(returning: ReminderBatch(reminders: reminders ?? []))
            }
        }
        return batch.reminders
    }

    private func resolveLists(named name: String?) throws -> [EKCalendar]? {
        guard let name else { return nil }
        let matches = store.calendars(for: .reminder).filter { $0.title == name }
        guard !matches.isEmpty else {
            let available = store.calendars(for: .reminder).map(\.title).joined(separator: ", ")
            throw ConnectorError("No reminders list named '\(name)'. Available: \(available)")
        }
        return matches
    }

    private func ensureFullAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                store.requestFullAccessToReminders { granted, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: granted) }
                }
            }
            guard granted else { throw ConnectorError("Reminders access was not granted.") }
        default:
            throw ConnectorError("Reminders access is denied. Enable it in System Settings → Privacy & Security → Reminders.")
        }
    }
}
