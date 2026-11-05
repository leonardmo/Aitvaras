import Foundation

/// A click authorizes a transition; only a provider acknowledgement applies it.
struct AgentModeState: Sendable {
    private(set) var mode: AgentMode
    private var approvedPlan: AgentRequest?

    init(_ mode: AgentMode) { self.mode = mode }

    mutating func approve(_ request: AgentRequest) {
        approvedPlan = request
    }

    mutating func acknowledgePlan(itemID: String?) -> Bool {
        guard let plan = approvedPlan, let itemID, plan.scope.itemID == itemID else { return false }
        acknowledge(.ask)
        return true
    }

    mutating func acknowledge(_ mode: AgentMode) {
        self.mode = mode; approvedPlan = nil
    }

    mutating func cancel() { approvedPlan = nil }
}
