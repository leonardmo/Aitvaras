import Foundation
import AitvarasAgents

extension Stores: PendingSendPersistence {
    public func pendingSend() throws -> PendingSend? {
        guard let value = try value(forKey: "agent.pendingSend"), !value.isEmpty else { return nil }
        guard value.utf8.count <= PendingSend.maximumBytes * 3 else { throw AgentFailure.invalidRequest }
        return try JSONDecoder().decode(PendingSend.self, from: Data(value.utf8))
    }
    public func savePendingSend(_ pending: PendingSend?) throws {
        let value: String
        if let pending {
            guard pending.text.utf8.count <= PendingSend.maximumBytes else { throw AgentFailure.invalidRequest }
            let data = try JSONEncoder().encode(pending)
            guard data.count <= PendingSend.maximumBytes * 3 else { throw AgentFailure.invalidRequest }
            value = String(decoding: data, as: UTF8.self)
        } else { value = "" }
        try setValue(value, forKey: "agent.pendingSend")
    }
}
