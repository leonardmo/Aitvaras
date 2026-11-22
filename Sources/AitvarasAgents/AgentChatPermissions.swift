import Foundation

/// A chat's saved tool policy, independent of the selected provider.
public struct AgentChatPermissions: Codable, Equatable, Sendable {
    public enum Commands: String, Codable, CaseIterable, Sendable {
        case ask, auto, unrestricted
    }

    public enum MCP: String, Codable, CaseIterable, Sendable {
        case ask, auto, unprompted
    }

    public var commands: Commands
    public var mcp: MCP
    public var isPlan: Bool

    public init(commands: Commands, mcp: MCP, isPlan: Bool = false) {
        self.commands = commands
        self.mcp = mcp
        self.isPlan = isPlan
    }

    public static let ask = Self(commands: .ask, mcp: .ask)
    public static let auto = Self(commands: .auto, mcp: .auto)
    public static let fullAccess = Self(commands: .unrestricted, mcp: .unprompted)
    public static let plan = Self(commands: .ask, mcp: .ask, isPlan: true)

    public var isFullAccess: Bool { !isPlan && commands == .unrestricted && mcp == .unprompted }

    public init(legacy mode: AgentMode) {
        switch mode {
        case .ask, .acceptEdits: self = .ask
        case .auto: self = .auto
        case .plan: self = .plan
        }
    }

    /// Used for native plan UI and older adapters. Tool execution uses the
    /// explicit command and MCP policies when available.
    public var mode: AgentMode {
        if isPlan { return .plan }
        if commands != .ask { return .auto }
        return .ask
    }
}
