import Foundation

/// Source-offset styling and list editing for an in-progress Markdown draft.
public struct ComposerMarkdown {
    public enum Style: Equatable {
        case heading(Int), strong, emphasis, code, quote, link, strike, syntax, bullet, ordered
    }

    public struct Span {
        public let style: Style
        public let range: NSRange
    }

    public struct NewlineEdit: Equatable {
        public let text: String
        public let range: NSRange
    }

    public let source: String
    public private(set) var spans: [Span] = []
    private var codeBlocks: [NSRange] = []
    private static let prefix = try! NSRegularExpression(pattern: #"^([ \t]*(?:>[ \t]*)*)(?:([-+*])|([0-9]{1,9})([.)]))([ \t]+|$)"#)
    private static let blockMarker = try! NSRegularExpression(pattern: #"^[ \t]*(?:#{1,6}[ \t]+|>[ \t]?)"#)

    public init(_ source: String = "") {
        self.source = source
        guard !source.isEmpty else { return }
        let text = source as NSString
        for node in ChatMarkdownDocument(source).blocks { collect(node, in: text) }
        var lineStart = 0
        while lineStart < text.length {
            let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
            if !codeBlocks.contains(where: { NSLocationInRange(lineStart, $0) }),
               let list = Self.listPrefix(in: text.substring(with: line)) {
                spans.append(Span(style: list.number == nil ? .bullet : .ordered,
                    range: NSRange(location: lineStart + list.marker.location, length: list.marker.length)))
            }
            lineStart = NSMaxRange(line)
        }
    }

    public func newlineEdit(at selection: NSRange) -> NewlineEdit? {
        let text = source as NSString
        guard selection.location >= 0, selection.length >= 0, selection.location <= text.length,
              selection.length <= text.length - selection.location else { return nil }
        if codeBlocks.contains(where: { selection.location >= $0.location && selection.location <= NSMaxRange($0) }) {
            return NewlineEdit(text: "\n", range: selection)
        }
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let content = text.substring(with: line).trimmingCharacters(in: .newlines)
        guard let prefix = Self.listPrefix(in: content),
              selection.location >= line.location + prefix.length,
              NSMaxRange(selection) <= line.location + (content as NSString).length else { return nil }
        let contents = (content as NSString).substring(from: prefix.length)
        if contents.trimmingCharacters(in: .whitespaces).isEmpty {
            return NewlineEdit(text: "", range: NSRange(location: line.location + (prefix.indentation as NSString).length,
                length: (content as NSString).length - (prefix.indentation as NSString).length))
        }
        let next = prefix.number.map { "\($0 + 1)\(prefix.symbol)" } ?? prefix.symbol
        return NewlineEdit(text: "\n" + prefix.indentation + next + " ", range: selection)
    }

    private struct ListPrefix {
        let indentation: String
        let number: Int?
        let symbol: String
        let marker: NSRange
        let length: Int
    }

    private static func listPrefix(in line: String) -> ListPrefix? {
        let line = line as NSString
        let contents = (line as String).trimmingCharacters(in: .newlines)
        guard let match = prefix.firstMatch(in: contents, range: NSRange(location: 0, length: contents.utf16.count)),
              match.range(at: 5).length > 0 else { return nil }
        let unordered = match.range(at: 2)
        let numeral = match.range(at: 3)
        let symbol = unordered.length > 0 ? unordered : match.range(at: 4)
        return ListPrefix(indentation: line.substring(with: match.range(at: 1)),
            number: numeral.length > 0 ? Int(line.substring(with: numeral)) : nil,
            symbol: line.substring(with: symbol), marker: numeral.length > 0 ? NSUnionRange(numeral, symbol) : symbol,
            length: match.range.length)
    }

    private mutating func collect(_ node: ChatMarkdownNode, in text: NSString) {
        if let range = node.sourceRange, range.length > 0, NSMaxRange(range) <= text.length {
            switch node.kind {
            case .heading, .blockquote:
                spans.append(Span(style: node.kind == .heading ? .heading(node.level ?? 1) : .quote, range: range))
                let line = text.substring(with: range)
                if let marker = Self.blockMarker.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) {
                    spans.append(Span(style: .syntax, range: NSRange(location: range.location, length: marker.range.length)))
                }
            case .codeBlock:
                codeBlocks.append(range)
                spans.append(Span(style: .code, range: range))
            case .strong, .emphasis, .inlineCode, .strikethrough:
                let style: Style
                let marker: Int
                switch node.kind {
                case .strong: style = .strong; marker = 2
                case .strikethrough: style = .strike; marker = 2
                case .inlineCode:
                    style = .code
                    marker = text.substring(with: range).prefix(while: { $0 == "`" }).count
                default: style = .emphasis; marker = 1
                }
                if marker > 0, range.length > marker * 2 {
                    spans.append(Span(style: style, range: NSRange(location: range.location + marker, length: range.length - marker * 2)))
                    spans.append(Span(style: .syntax, range: NSRange(location: range.location, length: marker)))
                    spans.append(Span(style: .syntax, range: NSRange(location: NSMaxRange(range) - marker, length: marker)))
                }
            case .link:
                spans.append(Span(style: .link, range: range))
            default: break
            }
        }
        for child in node.children { collect(child, in: text) }
    }
}
