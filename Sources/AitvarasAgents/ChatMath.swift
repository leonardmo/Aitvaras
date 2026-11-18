import Foundation
import Markdown

/// Source coordinates are UTF-8 in cmark and UTF-16 in TextKit. Keep the
/// conversion linear, including for non-ASCII text and streamed suffixes.
struct ChatSourceCoordinates {
    let bytes: [UInt8]
    let utf16Offsets: [Int]
    let lines: [Int]

    init(_ text: String) {
        bytes = Array(text.utf8)
        var offsets = [Int](), lineStarts = [0], offset = 0
        for scalar in text.unicodeScalars {
            offsets.append(contentsOf: repeatElement(offset, count: scalar.utf8.count))
            offset += scalar.utf16.count
        }
        offsets.append(offset)
        for i in bytes.indices where bytes[i] == 10 { lineStarts.append(i + 1) }
        utf16Offsets = offsets; lines = lineStarts
    }
    func byteOffset(_ location: SourceLocation) -> Int {
        guard location.line > 0, location.line <= lines.count else { return bytes.count }
        return min(bytes.count, lines[location.line - 1] + max(0, location.column - 1))
    }
    func range(_ range: SourceRange?) -> NSRange? {
        guard let range else { return nil }
        return nsRange(byteOffset(range.lowerBound)..<byteOffset(range.upperBound))
    }
    func nsRange(_ range: Range<Int>) -> NSRange {
        NSRange(location: utf16Offsets[range.lowerBound], length: utf16Offsets[range.upperBound] - utf16Offsets[range.lowerBound])
    }
}

public struct ChatMathSpan: Equatable, Sendable {
    public let range: NSRange
    public let latex: String
    public let display: Bool
    public let closed: Bool
    let bytes: Range<Int>
}

public enum ChatMath {
    /// Code is identified by CommonMark, so arbitrary backtick runs, indented
    /// code and fenced code all exclude math. No HTML or image loader is used.
    public static func spans(in source: String) -> [ChatMathSpan] {
        let coordinates = ChatSourceCoordinates(source)
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var excluded: [Range<Int>] = []
        func collect(_ node: any Markup) {
            if node is CodeBlock || node is InlineCode, let range = node.range {
                excluded.append(coordinates.byteOffset(range.lowerBound)..<coordinates.byteOffset(range.upperBound))
            } else { for child in node.children { collect(child) } }
        }
        collect(document)
        return scan(coordinates, excluding: excluded)
    }

    private static func scan(_ coordinates: ChatSourceCoordinates, excluding: [Range<Int>]) -> [ChatMathSpan] {
        let bytes = coordinates.bytes
        var result: [ChatMathSpan] = [], i = 0, exclusion = 0
        func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
        func digit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
        while i < bytes.count {
            while exclusion < excluding.count && excluding[exclusion].upperBound <= i { exclusion += 1 }
            if exclusion < excluding.count, excluding[exclusion].contains(i) { i = excluding[exclusion].upperBound; continue }
            if bytes[i] == 92, i + 1 < bytes.count, ![40, 91].contains(bytes[i + 1]) { i += 2; continue }
            var close: [UInt8] = [], length = 0, display = false, dollar = false
            if bytes[i] == 36 {
                dollar = true
                if i + 1 < bytes.count, bytes[i + 1] == 36 { close = [36, 36]; length = 2; display = true }
                else if i + 1 < bytes.count, !whitespace(bytes[i + 1]) { close = [36]; length = 1 }
            } else if bytes[i] == 92, i + 1 < bytes.count {
                if bytes[i + 1] == 40 { close = [92, 41]; length = 2 }
                if bytes[i + 1] == 91 { close = [92, 93]; length = 2; display = true }
            }
            guard length > 0 else { i += 1; continue }
            let start = i, content = i + length
            let codeBoundary = excluding.dropFirst(exclusion).first { $0.lowerBound >= content }?.lowerBound ?? bytes.count
            let lineBoundary = display ? bytes.count : (bytes[content...].firstIndex(of: 10) ?? bytes.count)
            let limit = min(codeBoundary, lineBoundary)
            var end = content, found = false, interruptedDollar = false
            while end + close.count <= limit {
                if !display && [10, 13].contains(bytes[end]) { break }
                if Array(bytes[end..<(end + close.count)]) == close,
                   end > content,
                   (!dollar || display || (!whitespace(bytes[end - 1]) && (end + 1 == bytes.count || !digit(bytes[end + 1])))) {
                    found = true; break
                }
                if dollar && !display && bytes[end] == 36 { interruptedDollar = true; break }
                if bytes[end] == 92 && close.first != 92 { end += min(2, bytes.count - end) }
                else { end += 1 }
            }
            if found {
                i = end + close.count
            } else {
                end = interruptedDollar ? end : limit
                i = max(start + length, end)
                // An unpaired numeric dollar is currency, with ordinary text
                // styling. It must not consume a later independent formula.
                if dollar && !display && digit(bytes[content]) { continue }
            }
            result.append(ChatMathSpan(range: coordinates.nsRange(start..<i),
                latex: String(decoding: bytes[content..<end], as: UTF8.self), display: display, closed: found, bytes: start..<i))
        }
        return result
    }

    /// Mask with the same UTF-8 width and line breaks. AST source positions
    /// therefore still refer to the original Markdown, including LaTeX escapes.
    static func masked(_ source: String, spans: [ChatMathSpan]) -> String {
        var bytes = Array(source.utf8)
        for span in spans {
            for i in span.bytes where bytes[i] != 10 && bytes[i] != 13 { bytes[i] = 109 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
