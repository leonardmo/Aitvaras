import Foundation
import AitvarasCore

/// Stable public setting IDs. A destination is a page or project section in
/// the app's Settings window. Storage keys are deliberately independent.
public struct AitvarasSetting: Sendable, Equatable, Identifiable {
    public enum Scope: String, Sendable { case profile, project }
    public enum Risk: String, Sendable { case normal, sensitive, userOnly }
    public enum ValueType: Sendable, Equatable {
        case boolean
        case choice([String])
        case number(ClosedRange<Double>, integer: Bool)
        case text(maximum: Int)
        case collection
        case action

        public func accepts(_ value: JSONValue) -> Bool {
            switch self {
            case .boolean: value.boolValue != nil
            case .choice(let options): value.stringValue.map(options.contains) == true
            case .number(let bounds, let integer):
                value.doubleValue.map { bounds.contains($0) && (!integer || $0.rounded() == $0) } == true
            case .text(let maximum):
                value.stringValue.map { $0.utf8.count <= maximum && !$0.contains("\0") } == true
            case .collection: value.arrayValue != nil || value.objectValue != nil
            case .action: false
            }
        }

        public var schema: JSONValue {
            switch self {
            case .boolean: .object(["type": .string("boolean")])
            case .choice(let options): .object(["type": .string("string"), "enum": .array(options.map(JSONValue.string))])
            case .number(let bounds, let integer):
                .object(["type": .string(integer ? "integer" : "number"),
                         "minimum": .number(bounds.lowerBound), "maximum": .number(bounds.upperBound)])
            case .text(let maximum): .object(["type": .string("string"), "maxLength": .number(Double(maximum))])
            case .collection: .object(["type": .string("collection")])
            case .action: .object(["type": .string("action")])
            }
        }
    }

    public let id: String
    public let title: String
    public let scope: Scope
    public let destination: String
    public let risk: Risk
    public let valueType: ValueType
    public let hint: String?
    /// Whether the generic before/after card can apply this value. Sensitive
    /// settings with dedicated review forms use their own typed proposal.
    public let acceptsValueProposal: Bool

    static func setting(_ id: String, _ title: String, _ destination: String, _ type: ValueType,
                        scope: Scope = .profile, risk: Risk = .userOnly, editable: Bool = false,
                        hint: String? = nil) -> Self {
        .init(id: id, title: title, scope: scope, destination: destination, risk: risk,
              valueType: type, hint: hint, acceptsValueProposal: editable)
    }
}

public enum SettingsRegistry {
    public static let entries: [AitvarasSetting] = [
        .setting("appearance.mode", "Appearance", "avatar", .choice(["system", "light", "dark"]), risk: .normal, editable: true),
        .setting(AppMotion.overrideKey, "Always animate in Aitvaras", "avatar", .boolean, risk: .normal, editable: true,
                 hint: "Overrides macOS Reduce Motion for Aitvaras animations."),
        .setting("companion.presentation", "Companion display", "avatar", .choice(["avatar", "minimal"]), risk: .normal, editable: true),
        .setting("companion.character", "Companion character", "avatar", .choice(["creature", "human"]), risk: .normal, editable: true),
        .setting("companion.customAvatar", "Custom avatar", "avatar", .action),
        .setting("voice.language", "Listening language", "voice", .choice(["en-US", "de-DE"]), risk: .normal, editable: true),
        .setting("voice.volume", "Voice volume", "voice", .number(0...2, integer: false), risk: .normal, editable: true),
        .setting("voice.neuralVoice", "Neural voice installation", "voice", .action),
        .setting("capture.language", "Capture language", "capture", .choice(["en-US", "de-DE"]), risk: .normal, editable: true),
        .setting("capture.postprocessing", "Capture postprocessing", "capture", .choice(["localSummary", "transcriptOnly"]), risk: .normal, editable: true),
        .setting("capture.audioRetention", "Capture audio retention", "capture", .choice(["discard", "sevenDays", "untilDeleted"]),
                 risk: .sensitive, editable: true, hint: "Retained audio stays on this Mac until you remove it."),
        .setting("capture.audioArchive", "Saved source audio", "capture", .collection),
        .setting("capture.speechAssets", "On-device speech assets", "capture", .action),
        .setting("capture.summaryModel", "Capture summary model", "capture", .text(maximum: 200)),
        .setting("memory.schedule.mode", "Nightly memory schedule", "memory", .choice(["automatic", "fixedTime", "off"]), risk: .normal, editable: true),
        .setting("memory.schedule.earliestMinute", "Earliest automatic run", "memory", .number(0...1439, integer: true), risk: .normal, editable: true),
        .setting("memory.schedule.fixedMinute", "Fixed run time", "memory", .number(0...1439, integer: true), risk: .normal, editable: true),
        .setting("memory.schedule.wakeDelay", "Delay after wake", "memory", .number(0...120, integer: true), risk: .normal, editable: true),
        .setting("memory.schedule.power", "Power policy", "memory", .choice(["batteryAboveThreshold", "pluggedInOnly", "always"]), risk: .normal, editable: true),
        .setting("memory.schedule.batteryThreshold", "Minimum battery percentage", "memory", .number(5...100, integer: true), risk: .normal, editable: true),
        .setting("providers.profiles", "Provider profiles", "providers", .collection),
        .setting("providers.signIn", "Provider sign-in", "providers", .action),
        .setting("providers.defaultModel", "Default model and effort", "providers", .collection),
        .setting("models.installed", "Installed local models", "models", .collection),
        .setting("models.assignments", "Local model assignment", "models", .collection),
        .setting("models.download", "Local model downloads", "models", .action),
        .setting("cloud.featureRouting", "Cloud feature routing", "cloud", .collection, risk: .sensitive),
        .setting("cloud.dataSharing", "Cloud data sharing", "cloud", .action),
        .setting("connections.integrations", "Connected services", "connections", .collection),
        .setting("connections.credentials", "Connection credentials", "connections", .action),
        .setting("connections.servers", "Shared MCP server definitions", "connections", .collection, risk: .sensitive),
        .setting("connections.gatewayLauncher", "Gateway launcher installation", "connections", .action),
        .setting("connections.autonomy", "Connection autonomy", "connections", .collection, risk: .sensitive),
        .setting("routines.definitions", "Command routines", "routines", .collection, risk: .sensitive),
        .setting("routines.status", "Run or pause an approved routine", "routines", .collection, risk: .sensitive, editable: true,
                 hint: "Use the ID of an approved routine with active or paused. Only one routine can change in each proposal."),
        .setting("routines.schedule", "Routine schedules", "routines", .collection, risk: .sensitive),
        .setting("background.paused", "Pause automatic work", "background", .boolean, risk: .sensitive, editable: true),
        .setting("background.policy", "Automatic work policy", "background", .collection, risk: .sensitive),
        .setting("access.microphone", "Microphone access", "access", .action),
        .setting("access.speechRecognition", "Speech recognition access", "access", .action),
        .setting("access.calendar", "Calendar access", "access", .action),
        .setting("access.reminders", "Reminders access", "access", .action),
        .setting("access.mail", "Read-only Mail access", "access", .action),
        .setting("usage.history", "Usage and history", "usage", .action),
        .setting("project.name", "Project name", "general", .text(maximum: 200), scope: .project, risk: .normal, editable: true),
        .setting("project.visibility", "Project sidebar visibility", "general", .boolean, scope: .project),
        .setting("project.default", "Default project for new chats", "general", .boolean, scope: .project),
        .setting("project.instructions", "Project instructions", "general", .text(maximum: 8_000), scope: .project, risk: .sensitive, editable: true),
        .setting("project.folders", "Project folders", "folders", .collection, scope: .project, risk: .sensitive, editable: true,
                 hint: "Adding folders requires a separate review of provider file access."),
        .setting("project.folderAccess", "Provider access to project folders", "folders", .collection, scope: .project, risk: .sensitive),
        .setting("project.agentSetup", "Project agent configuration", "agent", .collection, scope: .project, risk: .sensitive),
        .setting("project.codexLink", "Codex project link", "codex", .action, scope: .project),
        .setting("project.gatewayTools", "Aitvaras tools available to the project", "gateway", .collection, scope: .project, risk: .sensitive, editable: true,
                 hint: "Only in this project. Approved profile tools can return personal data to the agent."),
        .setting("project.knowledgeSources", "Linked knowledge sources", "gateway", .collection, scope: .project, risk: .sensitive),
        .setting("project.mcpServers", "Project MCP servers", "servers", .collection, scope: .project, risk: .sensitive),
        .setting("project.mcpApprovals", "MCP tool approvals", "servers", .collection, scope: .project, risk: .sensitive,
                 hint: "Rules apply to this project and selected connection. Tool exceptions expire when the tool definition changes.")
    ]
    private static let indexed = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    public static subscript(id: String) -> AitvarasSetting? { indexed[id] }
}
