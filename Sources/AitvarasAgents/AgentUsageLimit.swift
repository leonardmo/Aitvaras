import Foundation

/// Normalized evidence only; raw provider diagnostics must never be persisted.
public struct AgentUsageLimit: Sendable, Equatable {
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
}

extension JSONValue {
    /// Reset timestamps are epoch seconds. Invalid numbers are unavailable.
    var usageResetDate: Date? {
        guard let seconds = doubleValue, seconds.isFinite, seconds > 0,
              seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
