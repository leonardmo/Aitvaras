import Foundation
import AitvarasCore
import AitvarasStore

/// Daily goals, set collaboratively in conversation ("let's plan my
/// day") and tracked by the focus coach. All writes are reversible.
public actor GoalsConnector: Connector {
    public nonisolated let id = "goals"
    public nonisolated let displayName = "Daily Goals"

    private let stores: Stores

    public init(stores: Stores) {
        self.stores = stores
    }

    public nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "list_today",
            description: "Today's goals with their ids and completion state. Use when the user asks about their plan, goals or progress.",
            parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
            risk: .read),
        ToolDefinition(
            name: "add_goal",
            description: "Add a goal for today (short imperative phrase, e.g. 'Finish the seminar slides').",
            parametersJSON: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#,
            risk: .reversibleWrite),
        ToolDefinition(
            name: "complete_goal",
            description: "Mark a goal as done (id from list_today).",
            parametersJSON: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#,
            risk: .reversibleWrite),
        ToolDefinition(
            name: "remove_goal",
            description: "Delete a goal that no longer applies (id from list_today).",
            parametersJSON: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#,
            risk: .reversibleWrite),
        ToolDefinition(
            name: "start_focus_session",
            description: "Start a focus session. While it runs, Aitvaras holds non-urgent notifications until the next break, watches for distraction from today's goals, and reminds about breaks. Use when the user says 'I want to focus now', 'let's study', 'start a session'.",
            parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
            risk: .reversibleWrite),
        ToolDefinition(
            name: "end_focus_session",
            description: "End the current focus session. Aitvaras delivers any held updates and a short session summary. Use for 'I'm done', 'stop focus', 'end session'.",
            parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
            risk: .reversibleWrite),
        ToolDefinition(
            name: "set_break_interval",
            description: "Set how often break reminders fire during a focus session, in minutes (e.g. 25 for pomodoro, 50 default). Use for 'remind me to break every 45 minutes'.",
            parametersJSON: #"{"type":"object","properties":{"minutes":{"type":"integer"}},"required":["minutes"]}"#,
            risk: .reversibleWrite)
    ]

    public func health() async -> ConnectorHealth { .ready }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        let args = try ToolArgs(json: argumentsJSON)
        switch toolName {
        case "list_today":
            let goals = try stores.goals(day: Goal.today())
            let focus = (try? stores.value(forKey: "focus.sessionActive")) == "1"
            let header = "Focus session: \(focus ? "ACTIVE — non-urgent notifications held" : "not running")"
            if goals.isEmpty { return header + "\nNo goals set for today yet." }
            return header + "\n" + goals.map { goal in
                #"{"id": "\#(goal.id.uuidString)", "text": "\#(goal.text.replacingOccurrences(of: "\"", with: "'"))", "done": \#(goal.done)}"#
            }.joined(separator: "\n")

        case "add_goal":
            let text = try args.requiredString("text")
            let goal = Goal(day: Goal.today(), text: text)
            try stores.saveGoal(goal)
            return #"{"id": "\#(goal.id.uuidString)", "added": true}"#

        case "complete_goal":
            let id = try Self.uuid(from: args)
            try stores.setGoalDone(id, done: true)
            return #"{"completed": true}"#

        case "remove_goal":
            let id = try Self.uuid(from: args)
            try stores.deleteGoal(id)
            return #"{"removed": true}"#

        case "start_focus_session":
            try stores.setValue("1", forKey: "focus.sessionActive")
            try stores.setValue(String(Date().timeIntervalSince1970), forKey: "focus.sessionStart")
            return "Focus session started — I'll hold non-urgent notifications, watch for distractions, and remind you to break. Say you're done to end it."

        case "end_focus_session":
            try stores.setValue("0", forKey: "focus.sessionActive")
            return "Focus session ended — I'll share anything held and a short summary."

        case "set_break_interval":
            let minutes = max(10, min(180, args.int("minutes") ?? 50))
            try stores.setValue(String(minutes), forKey: "focus.breakIntervalMin")
            return "Break reminders set to every \(minutes) minutes."

        default:
            throw ConnectorError("Unknown tool \(toolName)")
        }
    }

    private static func uuid(from args: ToolArgs) throws -> UUID {
        guard let id = UUID(uuidString: try args.requiredString("id")) else {
            throw ConnectorError("Invalid goal id — use list_today to get real ids.")
        }
        return id
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        AsyncStream { $0.finish() }
    }
}
