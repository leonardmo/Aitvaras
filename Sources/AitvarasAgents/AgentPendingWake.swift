import Foundation

public enum AgentWakeKind: String, Codable, Sendable { case wakeup, cron, backgroundTask, monitor }

/// A native timer belongs to one transport generation, not a resumable session.
public struct AgentPendingWake: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var chatID: UUID
    public var sessionID: UUID
    public var kind: AgentWakeKind
    public var fireAt: Date?
    public var cronSpec: String?
    public var prompt: String?
    public var nativeToolID: String
    public var createdAt: Date
    public var claimedTurnID: UUID?
    public var claimedAt: Date?
    public var firedAt: Date?
    public var transportID: UUID?
    public var recurring: Bool = true

    public init(chatID: UUID, sessionID: UUID, kind: AgentWakeKind, fireAt: Date? = nil,
                cronSpec: String? = nil, prompt: String? = nil, nativeToolID: String,
                transportID: UUID? = nil, now: Date = .now) {
        self.chatID = chatID; self.sessionID = sessionID; self.kind = kind; self.fireAt = fireAt
        self.cronSpec = cronSpec; self.prompt = prompt.map { String($0.prefix(16_384)) }
        self.nativeToolID = nativeToolID; self.transportID = transportID; createdAt = now
    }
    public var survivesTransport: Bool { kind == .wakeup || kind == .cron }
    public func isAppOwned(at now: Date) -> Bool {
        transportID == nil || (survivesTransport && fireAt.map { now.timeIntervalSince($0) > 120 } == true)
    }
    public func scheduledPrompt(at now: Date) -> String {
        let due = fireAt?.formatted(date: .abbreviated, time: .shortened) ?? "unknown"
        return "Scheduled wake-up (was due \(due)\(now > (fireAt ?? now) ? ", fired late after restart or sleep" : "")):\n" + (prompt ?? "Continue the scheduled check.")
    }
}

public protocol AgentWakePersistence: Sendable {
    func pendingAgentWakes(chatID: UUID?) throws -> [AgentPendingWake]
    func saveAgentWake(_ wake: AgentPendingWake) throws
    func deleteAgentWake(id: UUID) throws
    func cancelAppOwnedAgentWake(id: UUID) throws
    func claimAgentWake(id: UUID, now: Date) throws -> AgentPendingWake?
    func finishAgentWake(id: UUID, now: Date) throws
    func releaseAgentWakeClaim(id: UUID) throws
    func releaseAgentWakeTransport(_ transportID: UUID?) throws
}

/// Standard five-field cron, evaluated in the device's current calendar/time zone.
/// An absent/invalid next occurrence is retained for visibility, never guessed.
public enum AgentWakeCron {
    public static func next(_ spec: String, after date: Date, calendar: Calendar = .current) -> Date? {
        guard spec.count <= 256 else { return nil }
        let fields = spec.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { return nil }
        let bounds = [0...59, 0...23, 1...31, 1...12, 0...7]
        var sets: [Set<Int>] = []
        for (field, bound) in zip(fields, bounds) {
            var values = Set<Int>()
            for part in field.split(separator: ",", omittingEmptySubsequences: false) {
                let stepParts = part.split(separator: "/", omittingEmptySubsequences: false)
                guard (1...2).contains(stepParts.count), let base = stepParts.first else { return nil }
                let step = stepParts.count == 2 ? Int(stepParts[1]) : 1
                guard let step, step > 0, step <= bound.upperBound + 1 else { return nil }
                let range: ClosedRange<Int>
                if base == "*" { range = bound }
                else {
                    let ends = base.split(separator: "-", omittingEmptySubsequences: false)
                    guard (1...2).contains(ends.count), let lo = Int(ends[0]), bound.contains(lo),
                          let hi = ends.count == 2 ? Int(ends[1]) : (stepParts.count == 2 ? bound.upperBound : lo),
                          bound.contains(hi), lo <= hi else { return nil }
                    range = lo...hi
                }
                for value in stride(from: range.lowerBound, through: range.upperBound, by: step) { values.insert(value) }
            }
            guard !values.isEmpty else { return nil }; sets.append(values)
        }
        var candidate = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60 + 60)
        // Include leap-day schedules while bounding malformed/unreachable combinations.
        let horizon = calendar.date(byAdding: .year, value: 5, to: candidate) ?? candidate
        while candidate < horizon {
            let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            let dow = (c.weekday ?? 1) - 1
            let day = sets[2].contains(c.day ?? 0)
            let week = sets[4].contains(dow) || (dow == 0 && sets[4].contains(7))
            let dayMatches = fields[2] == "*" ? week : fields[4] == "*" ? day : day || week
            if !sets[3].contains(c.month ?? 0) || !dayMatches {
                guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: candidate)) else { return nil }
                candidate = next
            } else if !sets[1].contains(c.hour ?? -1) {
                guard let next = calendar.dateInterval(of: .hour, for: candidate)?.end, next > candidate else { return nil }
                candidate = next
            } else if sets[0].contains(c.minute ?? -1) { return candidate }
            else { candidate.addTimeInterval(60) }
        }
        return nil
    }
}
