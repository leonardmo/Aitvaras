import AppKit
import Markdown
import SwiftMath

public extension NSAttributedString.Key {
    static let chatBlockKind = NSAttributedString.Key("AitvarasChatBlockKind")
    static let chatCodeBlock = NSAttributedString.Key("AitvarasChatCodeBlock")
}

public struct ChatCodeBlock {
    public let range: NSRange
    public let contentRange: NSRange
    public let code: String
    public let language: String
}

/// One native text storage for the whole message: selections can cross every
/// paragraph, table, code block and equation. No browser or network machinery.
@MainActor public final class ChatRichTextRenderer {
    public private(set) var source = ""
    public private(set) var text = NSMutableAttributedString(string: "")
    public private(set) var mappings: [ChatSourceSpan] = []
    public private(set) var codeBlocks: [ChatCodeBlock] = []
    public private(set) var reparsedSourceRange = NSRange(location: 0, length: 0)
    public private(set) var replacedRenderedRange = NSRange(location: 0, length: 0)
    private var parser = ChatMarkdownStream()
    private var stableRenderedLength = 0
    private var appearance: NSAppearance.Name?

    public init() {}

    /// Completed top-level blocks stay in storage, with the same attachments.
    /// Keep the last block open: lists, setext headings and tables can extend
    /// on the next line. Non-append edits and appearance changes rebuild once.
    @discardableResult public func update(_ value: String, appearance: NSAppearance.Name? = nil) -> Bool {
        guard let update = parser.update(value, reset: self.appearance != appearance) else { return false }
        if update.sourceRange.location == 0 { stableRenderedLength = 0 }
        source = value; self.appearance = appearance
        // The retained prefix may already end in a line break; the builder must
        // know, or a streamed suffix adds a separator a full render would not.
        let precededByNewline = stableRenderedLength > 0 && stableRenderedLength <= text.length
            && (text.string as NSString).character(at: stableRenderedLength - 1) == 10
        let builder = ChatRichTextBuilder(parsed: update.document, sourceBase: update.sourceRange.location,
                                          renderedBase: stableRenderedLength, precededByNewline: precededByNewline)
        builder.build()
        reparsedSourceRange = update.sourceRange
        replacedRenderedRange = NSRange(location: stableRenderedLength, length: text.length - stableRenderedLength)
        text.replaceCharacters(in: replacedRenderedRange, with: builder.output)
        mappings.removeAll { NSMaxRange($0.rendered) > stableRenderedLength }
        mappings.append(contentsOf: builder.mappings)
        codeBlocks.removeAll { NSMaxRange($0.range) > stableRenderedLength }
        codeBlocks.append(contentsOf: builder.codeBlocks)
        stableRenderedLength += builder.stableRenderedLength
        if update.document.hasReferenceDefinition { stableRenderedLength = 0 }
        return true
    }

    /// Copy/quote the Markdown represented by a visible selection. Fully
    /// selected formatting includes its delimiters; partial words stay partial.
    public func markdown(for selection: NSRange) -> String? {
        ChatSourceSelection.markdown(source: source, renderedLength: text.length, mappings: mappings, selection: selection)
    }
}

@MainActor private final class ChatRichTextBuilder {
    let source: String
    let coordinates: ChatSourceCoordinates
    let sourceBase: Int
    let renderedBase: Int
    let math: [ChatMathSpan]
    let document: Document
    let stableBoundary: Int
    var output = NSMutableAttributedString(string: "")
    var mappings: [ChatSourceSpan] = []
    var codeBlocks: [ChatCodeBlock] = []
    var stableRenderedLength = 0
    var emittedMath: Set<Int> = []

    struct Style {
        var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var color = NSColor.labelColor
        var indent: CGFloat = 0
        var strike = false
        var code = false
        var link: URL?
        var paragraph: NSParagraphStyle?
        var kind = "paragraph"
        var attributes: [NSAttributedString.Key: Any] {
            let p = (paragraph?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            p.headIndent = indent; p.firstLineHeadIndent = indent
            p.paragraphSpacing = 6
            var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color,
                .paragraphStyle: p, .chatBlockKind: kind]
            if strike { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if code { result[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12) }
            if let link { result[.link] = link; result[.foregroundColor] = NSColor.linkColor }
            return result
        }
    }

    let precededByNewline: Bool
    init(parsed: ChatMarkdownDocument, sourceBase: Int, renderedBase: Int, precededByNewline: Bool = false) {
        source = parsed.source; self.sourceBase = sourceBase; self.renderedBase = renderedBase
        self.precededByNewline = precededByNewline
        coordinates = parsed.coordinates; math = parsed.math; document = parsed.document
        stableBoundary = parsed.stableUTF16Length
    }

    func build() {
        let blocks = Array(document.children)
        for block in blocks {
            if coordinates.range(block.range)?.location == stableBoundary {
                stableRenderedLength = output.length
            }
            render(block, style: Style())
        }
    }

    func append(_ value: String, _ style: Style) { output.append(NSAttributedString(string: value, attributes: style.attributes)) }
    func map(_ node: any Markup, from start: Int, exact: Bool = false) {
        guard output.length > start, let range = coordinates.range(node.range) else { return }
        // A display equation may span multiple AST paragraphs. A paragraph
        // starting inside it must not claim the equation's trailing source for
        // a selection of the ordinary text that follows the attachment.
        guard !math.contains(where: { $0.range.location < range.location && range.location < NSMaxRange($0.range) }) else { return }
        var end = output.length
        let characters = output.string as NSString
        while end > start && characters.character(at: end - 1) == 10 { end -= 1 }
        guard end > start else { return }
        mappings.append(ChatSourceSpan(rendered: NSRange(location: renderedBase + start, length: end - start),
            source: NSRange(location: sourceBase + range.location, length: range.length), exact: exact))
    }
    func mapRange(_ sourceRange: NSRange, from start: Int, exact: Bool) {
        guard output.length > start else { return }
        mappings.append(ChatSourceSpan(rendered: NSRange(location: renderedBase + start, length: output.length - start),
            source: NSRange(location: sourceBase + sourceRange.location, length: sourceRange.length), exact: exact))
    }
    func raw(_ node: any Markup) -> String { coordinates.range(node.range).map { (source as NSString).substring(with: $0) } ?? "" }
    func children(_ node: any Markup, _ style: Style) { for child in node.children { render(child, style: style) } }
    func newline(_ style: Style) {
        if output.length == 0 ? !precededByNewline : !output.string.hasSuffix("\n") { append("\n", style) }
    }

    func render(_ node: any Markup, style initial: Style) {
        var style = initial
        let start = output.length
        if let range = coordinates.range(node.range), math.contains(where: {
            emittedMath.contains($0.range.location) && range.location >= $0.range.location && NSMaxRange(range) <= NSMaxRange($0.range)
        }) { return }
        switch node {
        case let value as Markdown.Text:
            renderText(value, style)
            return
        case let value as Heading:
            style.font = .systemFont(ofSize: max(14, 26 - CGFloat(value.level) * 2), weight: .semibold)
            style.kind = "heading"
            children(node, style); newline(style)
        case is Strong:
            style.font = NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask)
            children(node, style)
        case is Emphasis:
            style.font = NSFontManager.shared.convert(style.font, toHaveTrait: .italicFontMask)
            children(node, style)
        case is Strikethrough:
            style.strike = true; children(node, style)
        case let value as InlineCode:
            style.font = .monospacedSystemFont(ofSize: style.font.pointSize, weight: .regular); style.code = true
            append(value.code, style)
            // Map the contents too, for a partial selection inside a code span.
            let raw = raw(node), ticks = raw.prefix(while: { $0 == "`" }).count
            if let range = coordinates.range(node.range), raw.utf16.count == value.code.utf16.count + 2 * ticks {
                mapRange(NSRange(location: range.location + ticks, length: value.code.utf16.count), from: start, exact: true)
            }
        case let value as CodeBlock:
            renderCode(value, style)
        case is BlockQuote:
            style.indent += 16; style.color = .secondaryLabelColor; style.kind = "blockquote"
            children(node, style)
        case let list as OrderedList:
            renderList(list, startNumber: Int(list.startIndex), style: style)
        case is UnorderedList:
            renderList(node, startNumber: nil, style: style)
        case is Paragraph:
            children(node, style); newline(style)
        case is SoftBreak:
            append(" ", style)
        case is LineBreak:
            append("\n", style)
        case let value as Link:
            style.link = Self.browserURL(value.destination)
            children(node, style)
        case let value as Markdown.Image:
            style.link = Self.browserURL(value.source)
            style.kind = "imageLink"
            append(value.plainText.isEmpty ? (value.source ?? "Image") : value.plainText, style)
        case let table as Markdown.Table:
            renderTable(table, style)
        case is ThematicBreak:
            style.kind = "rule"; style.color = .separatorColor
            append("────────────────────\n", style)
        case is HTMLBlock, is InlineHTML:
            // Raw HTML is visible source, never executed or loaded.
            style.font = .monospacedSystemFont(ofSize: style.font.pointSize, weight: .regular)
            append(raw(node), style); if node is HTMLBlock { newline(style) }
        default:
            if node.childCount > 0 { children(node, style) }
            else { append(raw(node), style) }
        }
        map(node, from: start)
    }

    static func browserURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    func renderText(_ node: Markdown.Text, _ style: Style) {
        guard let range = coordinates.range(node.range) else { append(node.string, style); return }
        let matches = math.filter { NSIntersectionRange($0.range, range).length > 0 }
        if matches.isEmpty {
            let start = output.length; append(node.string, style)
            mappings.append(contentsOf: ChatSourceSelection.inlineSpans(source: (source as NSString).substring(with: range),
                rendered: node.string, sourceOffset: sourceBase + range.location, renderedOffset: renderedBase + start))
            return
        }
        var cursor = range.location
        for span in matches {
            if cursor < span.range.location {
                let part = NSRange(location: cursor, length: span.range.location - cursor), start = output.length
                append((source as NSString).substring(with: part), style); mapRange(part, from: start, exact: true)
            }
            if emittedMath.insert(span.range.location).inserted { renderMath(span, style) }
            cursor = max(cursor, NSMaxRange(span.range))
        }
        if cursor < NSMaxRange(range) {
            let part = NSRange(location: cursor, length: NSMaxRange(range) - cursor), start = output.length
            append((source as NSString).substring(with: part), style); mapRange(part, from: start, exact: true)
        }
    }

    func renderMath(_ span: ChatMathSpan, _ initial: Style) {
        var style = initial
        if span.display { newline(style) }
        let start = output.length
        if span.display { let p = NSMutableParagraphStyle(); p.alignment = .center; style.paragraph = p }
        var formula = MathImage(latex: span.latex, fontSize: style.font.pointSize,
            textColor: style.color, labelMode: span.display ? .display : .text, textAlignment: .left)
        if span.closed && span.latex.utf16.count <= 8192 && Self.safeMathDepth(span.latex) {
            let (error, image, layout) = formula.asImage()
            if error == nil, let image, let layout, image.size.width.isFinite, image.size.height.isFinite {
                let attachment = NSTextAttachment()
                attachment.image = image
                // Attachment y is measured from the surrounding baseline.
                attachment.bounds = CGRect(x: 0, y: -layout.descent, width: image.size.width, height: image.size.height)
                let value = NSMutableAttributedString(attachment: attachment)
                value.addAttributes(style.attributes, range: NSRange(location: 0, length: value.length))
                output.append(value)
                mapRange(span.range, from: start, exact: false)
                if span.display { append("\n", style) }
                return
            }
        }
        style.font = .monospacedSystemFont(ofSize: style.font.pointSize, weight: .regular)
        append((source as NSString).substring(with: span.range), style)
        mapRange(span.range, from: start, exact: true)
        if span.display { newline(style) }
    }

    static func safeMathDepth(_ source: String) -> Bool {
        var depth = 0
        for character in source {
            if character == "{" { depth += 1; if depth > 64 { return false } }
            if character == "}" { depth -= 1 }
        }
        return true
    }

    func renderList(_ list: any Markup, startNumber: Int?, style initial: Style) {
        var style = initial
        style.indent += 18; style.kind = "list"
        for (index, child) in list.children.enumerated() {
            let start = output.length
            let checkbox = (child as? ListItem)?.checkbox
            let marker: String
            if let checkbox { marker = checkbox == .checked ? "☑ " : "☐ " }
            else { marker = startNumber.map { "\($0 + index). " } ?? "• " }
            append(marker, style)
            children(child, style); newline(style)
            map(child, from: start)
        }
    }

    func renderCode(_ block: CodeBlock, _ initial: Style) {
        var style = initial
        style.font = .monospacedSystemFont(ofSize: initial.font.pointSize, weight: .regular)
        style.kind = "code"; style.code = true
        let literal = raw(block), lines = literal.components(separatedBy: "\n")
        let opening = (lines.first ?? "").trimmingCharacters(in: .whitespaces)
        if let mark = opening.first, mark == "`" || mark == "~" {
            let count = opening.prefix(while: { $0 == mark }).count
            var quoteDepth = 0, ancestor = block.parent
            while let parent = ancestor {
                if parent is BlockQuote { quoteDepth += 1 }
                ancestor = parent.parent
            }
            let closed = lines.dropFirst().contains {
                var line = $0.trimmingCharacters(in: .whitespaces)
                for _ in 0..<quoteDepth where line.hasPrefix(">") {
                    line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                return line.count >= count && line.allSatisfy { $0 == mark }
            }
            if !closed {
                let start = output.length; append(literal, style)
                if let range = coordinates.range(block.range) { mapRange(range, from: start, exact: true) }
                newline(style); return
            }
        }
        let start = output.length
        let language = block.language ?? "Code"
        append(language + "\n", style)
        let contentStart = output.length
        append(block.code, style); newline(style)
        let contentEnd = output.length
        // An empty footer reserves space for the horizontal scrollbar.
        append("\n", style)
        let range = NSRange(location: start, length: output.length - start)
        output.addAttribute(.chatCodeBlock, value: renderedBase + start, range: range)
        if let sourceRange = coordinates.range(block.range), let newline = literal.firstIndex(of: "\n") {
            let offset = literal[..<literal.index(after: newline)].utf16.count
            let codeRange = NSRange(location: sourceRange.location + offset, length: min(block.code.utf16.count, max(0, sourceRange.length - offset)))
            mappings.append(ChatSourceSpan(rendered: NSRange(location: renderedBase + contentStart, length: contentEnd - contentStart),
                source: NSRange(location: sourceBase + codeRange.location, length: codeRange.length), exact: block.code.utf16.count == codeRange.length))
        }
        codeBlocks.append(ChatCodeBlock(range: NSRange(location: renderedBase + start, length: range.length),
            contentRange: NSRange(location: renderedBase + contentStart, length: contentEnd - contentStart), code: block.code, language: language))
    }

    func renderTable(_ table: Markdown.Table, _ initial: Style) {
        let native = NSTextTable()
        native.numberOfColumns = max(1, table.maxColumnCount)
        native.layoutAlgorithm = .fixedLayoutAlgorithm
        native.setValue(100, type: .percentageValueType, for: .width)
        let rows = [Array(table.head.cells)] + table.body.rows.map { Array($0.cells) }
        for (rowIndex, row) in rows.enumerated() {
            for (column, cell) in row.enumerated() {
                let start = output.length
                var style = initial
                style.kind = "table"
                if rowIndex == 0 { style.font = .boldSystemFont(ofSize: style.font.pointSize) }
                let block = NSTextTableBlock(table: native, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(.separatorColor)
                block.setValue(100 / CGFloat(native.numberOfColumns), type: .percentageValueType, for: .width)
                if rowIndex == 0 { block.backgroundColor = .quaternaryLabelColor.withAlphaComponent(0.1) }
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                if column < table.columnAlignments.count {
                    switch table.columnAlignments[column] {
                    case .center: paragraph.alignment = .center
                    case .right: paragraph.alignment = .right
                    default: paragraph.alignment = .left
                    }
                }
                style.paragraph = paragraph
                children(cell, style); append("\n", style); map(cell, from: start)
            }
        }
    }
}
