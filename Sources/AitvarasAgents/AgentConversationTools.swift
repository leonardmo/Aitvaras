import Foundation

public struct AgentForkOrigin: Sendable, Codable, Equatable {
    public let chatID: UUID
    public let sessionID: UUID
    public let native: AgentSessionID
    public let assistantMessageID: String
    public var pending: Bool
    public init(chatID: UUID, sessionID: UUID, native: AgentSessionID, assistantMessageID: String, pending: Bool = true) {
        self.chatID = chatID; self.sessionID = sessionID; self.native = native
        self.assistantMessageID = assistantMessageID; self.pending = pending
    }
}

public enum AgentConversationError: Error, Sendable, Equatable {
    case unavailable, invalidMessage, busy, timedOut, invalidResponse, dirtyWorktree
    case worktreeUnavailable(UUID)
    public static let dirtyWorktreeReason = "Commit or discard the changes in this chat's worktree first"
}

public enum AgentConversationText {
    public static func quote(_ text: String, selection: String? = nil) -> String {
        let value = selection.flatMap { $0.isEmpty ? nil : $0 } ?? text
        return value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
    }
    public static func appending(_ context: String, to draft: String) -> String {
        draft.isEmpty ? context + "\n\n" : draft + (draft.hasSuffix("\n\n") ? "" : "\n\n") + context + "\n\n"
    }
    public static func sideQuestion(in draft: String) -> String? {
        guard draft.hasPrefix("/btw"), draft.count == 4 || draft.dropFirst(4).first?.isWhitespace == true else { return nil }
        return String(draft.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static let sideQuestionUnavailable = "Side questions are available for Claude chats with a native session."
}

public struct AgentDiffLine: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable { case header, context, added, removed }
    public let id: Int
    public let text: String
    public let kind: Kind
    public let oldLine: Int?
    public let newLine: Int?
}

public struct AgentDiffSelection: Sendable, Equatable {
    public private(set) var selected: Set<Int> = []
    public private(set) var anchor: Int?
    public init() {}
    public mutating func select(_ id: Int, in lines: [AgentDiffLine], extending: Bool = false, toggling: Bool = false) {
        guard lines.contains(where: { $0.id == id && $0.kind != .header }) else { return }
        if extending, let anchor {
            let range = min(anchor, id)...max(anchor, id)
            let values = lines.filter { range.contains($0.id) }
            // A range belongs to one hunk, and stale anchors cannot select data.
            guard values.contains(where: { $0.id == anchor }), !values.contains(where: { $0.kind == .header }) else { return }
            selected = Set(values.map(\.id))
        } else {
            if toggling {
                if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            } else { selected = [id] }
            anchor = id
        }
    }
}

public enum AgentDiffContext {
    public static func lines(_ diff: String) -> [AgentDiffLine] {
        var old: Int?, new: Int?, oldRemaining = 0, newRemaining = 0
        let expression = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        return diff.components(separatedBy: "\n").enumerated().map { index, line in
            if let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let ns = line as NSString
                func number(_ group: Int, fallback: Int) -> Int { match.range(at: group).location == NSNotFound ? fallback : Int(ns.substring(with: match.range(at: group))) ?? 0 }
                old = number(1, fallback: 0); oldRemaining = number(2, fallback: 1)
                new = number(3, fallback: 0); newRemaining = number(4, fallback: 1)
                return .init(id: index, text: line, kind: .header, oldLine: nil, newLine: nil)
            }
            let first = line.first
            if first == "-", oldRemaining > 0, let number = old {
                old = number + 1; oldRemaining -= 1
                return .init(id: index, text: String(line.dropFirst()), kind: .removed, oldLine: number, newLine: nil)
            }
            if first == "+", newRemaining > 0, let number = new {
                new = number + 1; newRemaining -= 1
                return .init(id: index, text: String(line.dropFirst()), kind: .added, oldLine: nil, newLine: number)
            }
            if first == " ", oldRemaining > 0, newRemaining > 0, let oldNumber = old, let newNumber = new {
                old = oldNumber + 1; new = newNumber + 1; oldRemaining -= 1; newRemaining -= 1
                return .init(id: index, text: String(line.dropFirst()), kind: .context, oldLine: oldNumber, newLine: newNumber)
            }
            return .init(id: index, text: line, kind: .header, oldLine: nil, newLine: nil)
        }
    }
    public static func message(path: String, diff: String, selected: Set<Int>) -> String? {
        let selected = lines(diff).filter { selected.contains($0.id) && $0.kind != .header }
        guard !selected.isEmpty else { return nil }
        let removedOnly = selected.allSatisfy { $0.kind == .removed }
        // Separate non-contiguous selections instead of claiming omitted lines
        // were selected. Replacement selections use the new-file range.
        var groups: [[AgentDiffLine]] = []
        for line in selected {
            if let last = groups.last?.last, last.id + 1 == line.id { groups[groups.count - 1].append(line) }
            else { groups.append([line]) }
        }
        let blocks = groups.compactMap { group -> String? in
            let numbers = group.compactMap { removedOnly ? $0.oldLine : $0.newLine }
            guard let first = numbers.min(), let last = numbers.max() else { return nil }
            let snippet = group.filter { removedOnly || $0.kind != .removed }
                .map { (removedOnly ? "-" : "") + $0.text }.joined(separator: "\n")
            let fence = String(repeating: "`", count: max(3, (snippet.components(separatedBy: CharacterSet(charactersIn: "`" ).inverted).map(\.count).max() ?? 0) + 1))
            return "\(path):L\(first)-L\(last)\n\(fence)\n\(snippet)\n\(fence)"
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }
}
