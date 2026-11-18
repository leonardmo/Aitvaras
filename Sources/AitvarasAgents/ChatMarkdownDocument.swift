import Foundation
import Markdown

/// AppKit-independent parsing shared by the native renderer and contract tests.
/// Destinations are data only: neither parsing nor rendering loads an image.
public struct ChatMarkdownNode: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case heading, paragraph, strong, emphasis, strikethrough, inlineCode, codeBlock
        case orderedList, unorderedList, listItem, blockquote, table, tableHead, tableBody, tableRow, tableCell
        case link, imageLink, rule, text, softBreak, lineBreak, literalHTML, other
    }
    public let kind: Kind
    public let sourceRange: NSRange?
    public let literal: String?
    public let destination: String?
    public let level: Int?
    public let startNumber: Int?
    public let checked: Bool?
    public let children: [ChatMarkdownNode]
}

public struct ChatMarkdownDocument {
    public let blocks: [ChatMarkdownNode]
    public let math: [ChatMathSpan]
    public let stableUTF16Length: Int
    var hasReferenceDefinition: Bool {
        guard let pattern = try? NSRegularExpression(pattern: #"(?m)^ {0,3}\[[^\]\n]+\]:\s*\S"#) else { return false }
        let matches = pattern.matches(in: source, range: NSRange(location: 0, length: source.utf16.count))
        guard !matches.isEmpty else { return false }
        var codeRanges: [NSRange] = []
        func collect(_ nodes: [ChatMarkdownNode]) {
            for node in nodes {
                if node.kind == .codeBlock, let range = node.sourceRange { codeRanges.append(range) }
                else { collect(node.children) }
            }
        }
        collect(blocks)
        return matches.contains { match in !codeRanges.contains { NSIntersectionRange($0, match.range).length > 0 } }
    }
    let source: String
    let document: Document
    let coordinates: ChatSourceCoordinates

    public init(_ source: String) {
        self.source = source
        coordinates = ChatSourceCoordinates(source)
        math = ChatMath.spans(in: source)
        document = Document(parsing: ChatMath.masked(source, spans: math), options: [.disableSmartOpts])
        let coordinates = coordinates
        func snapshot(_ node: any Markup) -> ChatMarkdownNode {
            let kind: ChatMarkdownNode.Kind
            var literal: String?, destination: String?, level: Int?, number: Int?, checked: Bool?
            switch node {
            case let value as Heading: kind = .heading; level = value.level
            case is Paragraph: kind = .paragraph
            case is Strong: kind = .strong
            case is Emphasis: kind = .emphasis
            case is Strikethrough: kind = .strikethrough
            case let value as InlineCode: kind = .inlineCode; literal = value.code
            case let value as CodeBlock: kind = .codeBlock; literal = value.code; destination = value.language
            case let value as OrderedList: kind = .orderedList; number = Int(value.startIndex)
            case is UnorderedList: kind = .unorderedList
            case let value as ListItem: kind = .listItem; checked = value.checkbox.map { $0 == .checked }
            case is BlockQuote: kind = .blockquote
            case is Markdown.Table: kind = .table
            case is Markdown.Table.Head: kind = .tableHead
            case is Markdown.Table.Body: kind = .tableBody
            case is Markdown.Table.Row: kind = .tableRow
            case is Markdown.Table.Cell: kind = .tableCell
            case let value as Link: kind = .link; destination = value.destination
            case let value as Markdown.Image: kind = .imageLink; destination = value.source
            case is ThematicBreak: kind = .rule
            case let value as Markdown.Text: kind = .text; literal = value.string
            case is SoftBreak: kind = .softBreak
            case is LineBreak: kind = .lineBreak
            case is HTMLBlock, is InlineHTML:
                kind = .literalHTML
                literal = coordinates.range(node.range).map { (source as NSString).substring(with: $0) }
            default: kind = .other
            }
            return ChatMarkdownNode(kind: kind, sourceRange: coordinates.range(node.range), literal: literal,
                destination: destination, level: level, startNumber: number, checked: checked, children: node.children.map(snapshot))
        }
        blocks = document.children.map(snapshot)
        var index = max(0, blocks.count - 1)
        while index > 0, let current = blocks[index].sourceRange, let previous = blocks[index - 1].sourceRange {
            let gap = NSRange(location: NSMaxRange(previous), length: max(0, current.location - NSMaxRange(previous)))
            let separator = (source as NSString).substring(with: gap)
            let blankLine = separator.range(of: #"\r?\n[ \t]*\r?\n"#, options: .regularExpression) != nil
            let crossingMath = math.contains { $0.range.location < current.location && NSMaxRange($0.range) > current.location }
            // An incomplete first table row can temporarily parse as a separate
            // paragraph. Keep adjoining blocks open until a blank separator;
            // otherwise that paragraph would permanently freeze an empty table.
            if blankLine && !crossingMath { break }
            index -= 1
        }
        stableUTF16Length = blocks.isEmpty ? 0 : (blocks[index].sourceRange?.location ?? 0)
    }
}

public struct ChatMarkdownUpdate {
    public let document: ChatMarkdownDocument
    public let sourceRange: NSRange
}

/// Retain completed blocks and parse just the open suffix of an append. Source
/// edits and link definitions are explicit invalidations, not streaming deltas.
public struct ChatMarkdownStream {
    public private(set) var source = ""
    private var stableLength = 0
    public init() {}

    public mutating func update(_ value: String, reset: Bool = false) -> ChatMarkdownUpdate? {
        guard !source.utf8.elementsEqual(value.utf8) || reset else { return nil }
        if reset || !value.utf8.starts(with: source.utf8) { stableLength = 0 }
        var suffix = (value as NSString).substring(from: stableLength)
        var parsed = ChatMarkdownDocument(suffix)
        if stableLength > 0 && parsed.hasReferenceDefinition {
            stableLength = 0; suffix = value; parsed = ChatMarkdownDocument(value)
        }
        let range = NSRange(location: stableLength, length: suffix.utf16.count)
        source = value
        stableLength += parsed.stableUTF16Length
        if parsed.hasReferenceDefinition { stableLength = 0 }
        return ChatMarkdownUpdate(document: parsed, sourceRange: range)
    }
}
