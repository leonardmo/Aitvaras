import Foundation

/// Native slash-command envelopes are a projection of the user's input. Only
/// recognize the complete envelope; ordinary XML-looking user text stays intact.
public enum ClaudeCommandText {
    public static func display(_ text: String) -> String {
        guard text.utf8.count <= 1_048_576,
              let pattern = try? NSRegularExpression(pattern: #"^\s*(?:<command-message>[^<]*</command-message>\s*)?<command-name>(/[^<>\s]+)</command-name>\s*(?:<command-args>([\s\S]*?)</command-args>)?\s*$"#),
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text) else { return text }
        let name = String(text[nameRange])
        guard let argsRange = Range(match.range(at: 2), in: text), !text[argsRange].isEmpty else { return name }
        let args = String(text[argsRange]).replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
        return name + " " + args
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
    public var displayText: String { provider == .claude && kind == "user" ? ClaudeCommandText.display(text) : text }
}
