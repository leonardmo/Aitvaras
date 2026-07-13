import Foundation

/// Central enforcement of D13: reads run freely, reversible writes run
/// immediately, everything else needs the user. Connectors never make
/// this decision themselves.
public struct AutonomyPolicy: Sendable {
    public enum Verdict: Sendable, Equatable {
        case allow
        case requireConfirmation
    }

    /// Tool names (as "connectorID.toolName") the user has whitelisted to
    /// run without confirmation despite being `confirmable`.
    public var whitelist: Set<String>

    public init(whitelist: Set<String> = []) {
        self.whitelist = whitelist
    }

    public func verdict(for tool: ToolDefinition, connectorID: String) -> Verdict {
        switch tool.risk {
        case .read, .reversibleWrite:
            return .allow
        case .confirmable:
            return whitelist.contains("\(connectorID).\(tool.name)") ? .allow : .requireConfirmation
        }
    }
}

/// Protocol for the embedding model behind RAG (D11) — swappable like
/// the inference engines.
public protocol EmbeddingEngine: Actor {
    var identifier: String { get }
    var dimensions: Int { get }
    func embed(texts: [String]) async throws -> [[Float]]
}
