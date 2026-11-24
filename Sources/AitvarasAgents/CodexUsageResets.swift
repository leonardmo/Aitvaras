import Foundation

public struct CodexUsageResetCredit: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let expiresAt: Date?

    init?(_ value: JSONValue, now: Date) {
        guard value["status"]?.stringValue == "available", value["resetType"]?.stringValue == "codexRateLimits",
              let id = value["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 512,
              !id.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        if let expiration = value["expiresAt"], expiration != .null {
            guard let date = expiration.usageResetDate, date > now else { return nil }
            expiresAt = date
        } else {
            expiresAt = nil
        }
        self.id = id
        title = value["title"]?.stringValue.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) } ?? "Codex usage reset"
    }
}

public struct CodexUsageResetBalance: Equatable, Sendable {
    public let availableCount: Int
    public let credits: [CodexUsageResetCredit]

    init?(_ value: JSONValue?, now: Date = .now) {
        guard let count = value?["availableCount"]?.int, count >= 0 else { return nil }
        availableCount = count
        var seen = Set<String>()
        credits = count == 0 ? [] : (value?["credits"]?.arrayValue ?? [])
            .compactMap { CodexUsageResetCredit($0, now: now) }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
}

public struct CodexUsageSnapshot: Sendable {
    public let windows: [AgentRateLimitWindow]
    public let resets: CodexUsageResetBalance?
}

public enum CodexUsageResetOutcome: String, Sendable {
    case reset, alreadyRedeemed, nothingToReset, noCredit
}
