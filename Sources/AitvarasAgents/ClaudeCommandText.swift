import Foundation

/// Native slash-command envelopes are a projection of the user's input. Only
/// recognize the complete envelope; ordinary XML-looking user text stays intact.
public enum ClaudeCommandText {
    private static let field = try! NSRegularExpression(
        pattern: #"\G\s*<(command-name|command-message|command-args)>([^<>]*)</\1>"#)

    public static func display(_ text: String) -> String { command(in: text) ?? text }

    static func command(in text: String) -> String? {
        guard text.utf8.count <= 1_048_576 else { return nil }
        var fields: [String: String] = [:]
        var end = text.startIndex
        for match in field.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), range.lowerBound == end,
                  let key = Range(match.range(at: 1), in: text),
                  let value = Range(match.range(at: 2), in: text),
                  fields.updateValue(String(text[value]), forKey: String(text[key])) == nil else { return nil }
            end = range.upperBound
        }
        guard fields.count == 3, text[end...].allSatisfy(\.isWhitespace),
              let name = fields["command-name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              name.hasPrefix("/"), name.count > 1, !name.contains(where: \.isWhitespace),
              let args = fields["command-args"] else { return nil }
        guard !args.isEmpty else { return name }
        return name + " " + args.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func messageText(_ content: JSONValue?) -> String? {
        if let text = content?.stringValue { return text }
        let parts = content?.arrayValue?.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil } ?? []
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func isCaveat(_ record: JSONValue) -> Bool {
        record["type"]?.stringValue == "user" && record["isMeta"]?.boolValue == true
            && messageText(record["message"]?["content"])?
                .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<local-command-caveat>") == true
    }

    static func output(in record: JSONValue) -> String? {
        let content: String?
        switch record["type"]?.stringValue {
        case "system":
            content = messageText(record["content"]) ?? messageText(record["message"]?["content"])
                ?? record["message"]?.stringValue ?? messageText(record["output"])
        case "assistant", "user": content = messageText(record["message"]?["content"])
        case "result": content = record["result"]?.stringValue
        default: return nil
        }
        guard var remaining = content?[...].drop(while: \.isWhitespace) else { return nil }
        var parts: [Substring] = []
        while !remaining.isEmpty {
            let tag: String
            if remaining.hasPrefix("<local-command-stdout>") { tag = "local-command-stdout" }
            else if remaining.hasPrefix("<local-command-stderr>") { tag = "local-command-stderr" }
            else { return nil }
            remaining = remaining.dropFirst(tag.count + 2)
            guard let close = remaining.range(of: "</\(tag)>") else { return nil }
            parts.append(remaining[..<close.lowerBound])
            remaining = remaining[close.upperBound...].drop(while: \.isWhitespace)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

public enum AgentComposerCaret {
    /// NSText uses UTF-16 offsets; programmatic edits always leave an empty selection.
    public static func afterInsertion(_ text: String) -> NSRange { NSRange(location: text.utf16.count, length: 0) }

    /// Replace the selection in NSText's UTF-16 coordinate space. Stale or
    /// invalid selections fall back to the end without splitting a character.
    public static func insertingNewline(in text: String, selection: NSRange?) -> (text: String, caret: NSRange) {
        let selected = selection.flatMap { range -> Range<String.Index>? in
            guard let range = Range(range, in: text),
                  range.lowerBound.samePosition(in: text.utf8) != nil,
                  range.upperBound.samePosition(in: text.utf8) != nil else { return nil }
            return range
        } ?? text.endIndex..<text.endIndex
        var result = text
        let offset = selected.lowerBound.utf16Offset(in: text)
        result.replaceSubrange(selected, with: "\n")
        return (result, NSRange(location: offset + 1, length: 0))
    }
}

extension AgentTranscriptEntry {
    public var claudeCommandOutput: String? {
        guard provider == .claude, kind == "user" else { return nil }
        return payloadJSON.flatMap(JSONValue.parse)?["claudeCommandOutput"]?.stringValue
    }

    public var displayText: String { provider == .claude && kind == "user" ? ClaudeCommandText.display(text) : text }
}
