import Foundation

/// Normalized evidence only; raw provider diagnostics must never be persisted.
public struct AgentUsageLimit: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case allowed, warning, rejected, unknown }
    public let status: Status
    public let windowID: String?
    public let resetsAt: Date?

    public init(status: Status, windowID: String? = nil, resetsAt: Date? = nil) {
        self.status = status; self.windowID = windowID; self.resetsAt = resetsAt
    }

    static func claude(_ value: JSONValue) -> Self {
        let status = Status(rawValue: value["status"]?.stringValue ?? "") ?? .unknown
        let rawWindow = value["rateLimitType"]?.stringValue
        let window = rawWindow.flatMap { ["five_hour", "seven_day"].contains($0) ? $0 : nil }
        let reset = window.flatMap { value["unifiedWindows"]?[$0]?["resetsAt"]?.usageResetDate }
            ?? (window == nil ? nil : value["resetsAt"]?.usageResetDate)
        return .init(status: status, windowID: window, resetsAt: reset)
    }

    func resolving(windows: [AgentRateLimitWindow]) -> Self {
        let exhausted = windows.filter { $0.utilization == 1 }
        let window = windowID.flatMap { id in windows.first { $0.id == id } }
            ?? (windowID == nil && exhausted.count == 1 ? exhausted.first : nil)
        return .init(status: status, windowID: windowID ?? window?.id, resetsAt: resetsAt ?? window?.resetsAt)
    }

    /// Only a typed usage error proves quota exhaustion; HTTP 429 alone does not.
    static func codex(_ error: JSONValue, windows: [AgentRateLimitWindow] = []) -> Self? {
        let data = error["data"] ?? error
        let info = data["codexErrorInfo"] ?? error["codexErrorInfo"]
        guard info?.stringValue == "usageLimitExceeded"
            || data["type"]?.stringValue == "usage_limit_reached"
            || data["code"]?.stringValue == "usage_limit_reached" else { return nil }
        let exhausted = windows.filter { $0.utilization == 1 }
        let name = data["rateLimitType"]?.stringValue
        let limitID = data["limitId"]?.stringValue ?? "codex"
        let explicitID = name.flatMap { ["primary", "secondary"].contains($0) ? limitID + "." + $0 : nil }
        let window = explicitID.flatMap { id in windows.first { $0.id == id } }
            ?? (explicitID == nil && exhausted.count == 1 ? exhausted.first : nil)
        return .init(status: .rejected, windowID: explicitID ?? window?.id,
                     resetsAt: data["resetsAt"]?.usageResetDate ?? window?.resetsAt)
    }

}

extension JSONValue {
    /// Reset timestamps are epoch seconds. Invalid numbers are unavailable.
    var usageResetDate: Date? {
        guard let seconds = doubleValue, seconds.isFinite, seconds > 0,
              seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Carries normalized evidence across the RPC barrier without raw error text.
struct AgentUsageLimitRejection: Error {
    let evidence: AgentUsageLimit
}
