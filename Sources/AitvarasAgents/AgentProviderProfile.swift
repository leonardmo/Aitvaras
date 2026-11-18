import Foundation

/// Explicit accounts are implemented for Claude only. Other providers retain
/// one implicit choice; the identity leaves room for additional kinds later.
public struct AgentProviderProfile: Codable, Sendable, Equatable, Identifiable {
    public static let defaultClaudeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public var id: UUID
    public var name: String
    public var kind: AgentProvider
    public var badge: String
    public var colour: String
    public var defaultModel: String
    public var defaultEffort: String
    public var configDirectory: String?
    public var sortOrder: Int
    public var createdAt: Date
    public var isDeleted: Bool
    public var nativeProfile: String { id == Self.defaultClaudeID ? "default" : id.uuidString }
    public var choice: AgentProviderChoice { .init(provider: kind, profile: nativeProfile) }
    public init(id: UUID = UUID(), name: String, badge: String = "C", colour: String = "orange",
                configDirectory: String? = nil, sortOrder: Int = 0, createdAt: Date = .now) {
        self.id = id; self.name = name; kind = .claude; self.badge = badge; self.colour = colour
        defaultModel = "opus"; defaultEffort = "medium"; self.configDirectory = configDirectory
        self.sortOrder = sortOrder; self.createdAt = createdAt; isDeleted = false
    }
}

public struct AgentProviderChoice: Hashable, Sendable, Identifiable {
    public let provider: AgentProvider
    public let profile: String
    public var id: String { profile == "default" ? provider.rawValue : provider.rawValue + ":" + profile }
    public init(provider: AgentProvider, profile: String = "default") {
        self.provider = provider; self.profile = provider == .claude ? profile : "default"
    }
    public init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let provider = AgentProvider(rawValue: first),
              parts.count == 1 || provider == .claude && UUID(uuidString: parts[1]) != nil else { return nil }
        self.init(provider: provider, profile: parts.count == 2 ? parts[1] : "default")
    }
    public static func inlineChoices(all: [Self], recent: [Self], selected: Self) -> [Self] {
        var seen = Set<Self>()
        return Array(([selected] + recent + all).filter { all.contains($0) && seen.insert($0).inserted }.prefix(3))
    }
}

/// A single backend owns every launch surface for one CLI home. The factory is
/// synchronous so manager startup and native history use exactly the same scope.
public final class AgentProfileBackends: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentProviderChoice: any AgentBackend] = [:]
    private let factory: @Sendable (AgentProviderChoice) throws -> any AgentBackend
    public init(factory: @escaping @Sendable (AgentProviderChoice) throws -> any AgentBackend) { self.factory = factory }
    public func backend(_ choice: AgentProviderChoice) throws -> any AgentBackend {
        lock.lock(); defer { lock.unlock() }
        if let value = values[choice] { return value }
        let value = try factory(choice); values[choice] = value; return value
    }
}
