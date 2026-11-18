import Foundation
import Markdown

public struct ChatSourceSpan: Sendable {
    public let rendered: NSRange
    public let source: NSRange
    let exact: Bool
}

public enum ChatSourceSelection {
    /// Cmark decodes escapes and entities. Preserve small source spans so a
    /// selection next to an entity still copies just the selected word.
    static func inlineSpans(source: String, rendered: String, sourceOffset: Int, renderedOffset: Int) -> [ChatSourceSpan] {
        if source == rendered {
            return [ChatSourceSpan(rendered: NSRange(location: renderedOffset, length: rendered.utf16.count),
                source: NSRange(location: sourceOffset, length: source.utf16.count), exact: true)]
        }
        var index = source.startIndex, visible = rendered.startIndex, result: [ChatSourceSpan] = []
        while index < source.endIndex, visible < rendered.endIndex {
            let start = index
            var end = source.index(after: index), decoded = String(source[index])
            if source[index] == "\\", end < source.endIndex,
               source[end].unicodeScalars.count == 1, let scalar = source[end].unicodeScalars.first,
               (33...47).contains(scalar.value) || (58...64).contains(scalar.value) || (91...96).contains(scalar.value) || (123...126).contains(scalar.value) {
                decoded = String(source[end]); end = source.index(after: end)
            } else if source[index] == "&", let semicolon = source[index...].prefix(40).firstIndex(of: ";") {
                let tokenEnd = source.index(after: semicolon), token = String(source[index..<tokenEnd])
                let paragraph = Document(parsing: token, options: [.disableSmartOpts]).child(at: 0) as? Paragraph
                if let value = paragraph?.plainText, value != token { decoded = value; end = tokenEnd }
            }
            guard rendered[visible...].hasPrefix(decoded) else {
                return [ChatSourceSpan(rendered: NSRange(location: renderedOffset, length: rendered.utf16.count),
                    source: NSRange(location: sourceOffset, length: source.utf16.count), exact: false)]
            }
            let next = rendered.index(visible, offsetBy: decoded.count)
            result.append(ChatSourceSpan(rendered: NSRange(location: renderedOffset + visible.utf16Offset(in: rendered), length: decoded.utf16.count),
                source: NSRange(location: sourceOffset + start.utf16Offset(in: source), length: source[start..<end].utf16.count),
                exact: String(source[start..<end]) == decoded))
            index = end; visible = next
        }
        return result
    }

    public static func markdown(source: String, renderedLength: Int, mappings: [ChatSourceSpan], selection: NSRange) -> String? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length > 0,
              selection.location <= renderedLength, selection.length <= renderedLength - selection.location else { return nil }
        var lower = Int.max, upper = 0
        for span in mappings {
            let intersection = NSIntersectionRange(selection, span.rendered)
            guard intersection.length > 0 else { continue }
            let range: NSRange
            if span.exact && span.rendered.length == span.source.length {
                range = NSRange(location: span.source.location + intersection.location - span.rendered.location, length: intersection.length)
            } else if NSEqualRanges(intersection, span.rendered) {
                range = span.source
            } else { continue }
            lower = min(lower, range.location); upper = max(upper, NSMaxRange(range))
        }
        guard lower < upper, upper <= source.utf16.count else { return nil }
        return (source as NSString).substring(with: NSRange(location: lower, length: upper - lower))
    }
}
