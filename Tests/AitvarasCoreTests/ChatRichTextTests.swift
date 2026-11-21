import AppKit
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct ChatComposerNewlineTests {
    @Test func insertsAtCaretAndReplacesSelectionUsingUTF16() {
        let cases: [(String, NSRange?, String, Int)] = [
            ("abc", NSRange(location: 1, length: 0), "a\nbc", 2),
            ("abcdef", NSRange(location: 2, length: 3), "ab\nf", 3),
            ("🐉日本語", NSRange(location: 2, length: 2), "🐉\n語", 3),
            ("a\nb", nil, "a\nb\n", 4),
            ("", nil, "\n", 1),
            ("abc", NSRange(location: 99, length: 1), "abc\n", 4),
            ("🐉", NSRange(location: 1, length: 0), "🐉\n", 3)
        ]
        for (source, selection, expected, caret) in cases {
            let edit = AgentComposerCaret.insertingNewline(in: source, selection: selection)
            #expect(edit.text == expected)
            #expect(edit.caret == NSRange(location: caret, length: 0))
        }
    }
}

@Suite(.timeLimit(.minutes(2))) struct ChatMathTests {
    @Test func detectsAllDelimitersAndLeavesCurrencyAndCodeLiteral() {
        let source = #"$x$ and \(y\), $$z$$ and \[w\]; costs $5 and $10; `$code$`"#
        let spans = ChatMath.spans(in: source).filter(\.closed)
        #expect(spans.map(\.latex) == ["x", "y", "z", "w"])
        #expect(spans.map(\.display) == [false, false, true, true])
        for source in [#"$ x$"#, #"$x $"#, #"$x$2"#, #"\$x\$"#, "``$x$``", "```latex\n$x$\n```", "~~~\n\\(x\\)\n~~~", "    $x$\n"] {
            #expect(ChatMath.spans(in: source).filter(\.closed).isEmpty, "\(source)")
        }
        #expect(ChatMath.spans(in: "$5$ and $x$").filter(\.closed).map(\.latex) == ["5", "x"])
        #expect(ChatMath.spans(in: "costs $5 and $10").isEmpty)
        #expect(ChatMath.spans(in: "costs $5 and $x$").filter(\.closed).map(\.latex) == ["x"])
    }

    @Test func unicodeRangesAndUnclosedInputAreLossless() {
        let source = #"🐉 über $α+β$ then \[\int_0^1"#
        let spans = ChatMath.spans(in: source)
        #expect(spans.count == 2)
        #expect((source as NSString).substring(with: spans[0].range) == "$α+β$")
        #expect(spans[1].closed == false)
        #expect(spans[1].display)
    }
}

@Suite(.timeLimit(.minutes(2))) struct ChatMarkdownStructureTests {
    func flatten(_ nodes: [ChatMarkdownNode]) -> [ChatMarkdownNode] { nodes.flatMap { [$0] + flatten($0.children) } }

    @Test func parsesEveryCommonMarkAndGFMConstructWithSourceRanges() {
        let source = """
        # Heading

        **bold** *italic* ~~gone~~ `literal` [link](https://example.invalid)

        3. item
           - nested

        - [x] checked
        - [ ] unchecked

        > quote

        ---

        | A | B |
        | --- | --- |
        | one | two |

        ```swift
        let x = "$literal$"
        ```

        ![image](https://example.invalid/image.png)

        <img src="https://example.invalid/never-load.png">
        """
        let document = ChatMarkdownDocument(source), nodes = flatten(document.blocks)
        let kinds = Set(nodes.map(\.kind))
        for kind: ChatMarkdownNode.Kind in [.heading, .strong, .emphasis, .strikethrough, .inlineCode,
            .link, .orderedList, .unorderedList, .listItem, .blockquote, .rule, .table, .tableHead,
            .tableBody, .tableRow, .tableCell, .codeBlock, .imageLink, .literalHTML] {
            #expect(kinds.contains(kind), "\(kind)")
        }
        #expect(nodes.first { $0.kind == .orderedList }?.startNumber == 3)
        #expect(nodes.filter { $0.kind == .listItem }.compactMap(\.checked) == [true, false])
        #expect(nodes.first { $0.kind == .codeBlock }?.literal == "let x = \"$literal$\"\n")
        #expect(nodes.first { $0.kind == .codeBlock }?.destination == "swift")
        #expect(nodes.first { $0.kind == .imageLink }?.destination == "https://example.invalid/image.png")
        #expect(document.math.isEmpty)
        for node in nodes where node.kind == .strong {
            #expect(node.sourceRange.map { (source as NSString).substring(with: $0) } == "**bold**")
        }
    }

    @Test func tailBoundaryKeepsExtensibleBlocksAndMultilineMathOpen() {
        let prefix = "# Stable\n\n"
        for tail in ["Paragraph", "- list\n  - nested", "| A |\n| --- |\n| value |", "```\nopen", "$$x\n\ny$$", "\\[x\n\ny\\]"] {
            let parsed = ChatMarkdownDocument(prefix + tail)
            #expect(parsed.stableUTF16Length == prefix.utf16.count, "\(tail)")
        }
    }

    @Test func streamingReparsesOnlyTheTailAndMatchesTheFinalDocument() throws {
        func shifted(_ node: ChatMarkdownNode, by offset: Int) -> ChatMarkdownNode {
            ChatMarkdownNode(kind: node.kind, sourceRange: node.sourceRange.map { NSRange(location: $0.location + offset, length: $0.length) },
                literal: node.literal, destination: node.destination, level: node.level, startNumber: node.startNumber,
                checked: node.checked, children: node.children.map { shifted($0, by: offset) })
        }
        let samples = [
            "# Stable\n\nParagraph **bold**.\n\n- one\n  - nested\n\nNext",
            "| A | B |\n| --- | --- |\n| one | two |\n\n```swift\n$x$\n```\n\nAfter",
            "Before\n\n$$\\int_0^1\n\nx dx$$\n\nAfter",
            "Before\n\n$$x$$\n\nAfter",
            "[link][ref]\n\nNext\n\n[ref]: https://example.invalid"
        ]
        for source in samples {
            var stream = ChatMarkdownStream(), partial = "", blocks: [ChatMarkdownNode] = []
            for character in source {
                partial.append(character)
                let next = stream.update(partial)
                let update = try #require(next)
                blocks.removeAll { NSMaxRange($0.sourceRange ?? NSRange(location: 0, length: 0)) > update.sourceRange.location }
                blocks.append(contentsOf: update.document.blocks.map { shifted($0, by: update.sourceRange.location) })
            }
            #expect(blocks == ChatMarkdownDocument(source).blocks, "\(source)")
            let unchanged = stream.update(source), edited = stream.update("Edited")
            #expect(unchanged == nil)
            #expect(edited?.sourceRange.location == 0)
        }
        var stream = ChatMarkdownStream(), source = "First\n\nSecond", parsedLength = 0
        _ = stream.update(source)
        for _ in 0..<100 {
            source += "\n\nNext paragraph"
            let next = stream.update(source)
            let update = try #require(next)
            parsedLength += update.sourceRange.length
            #expect(update.sourceRange.location > 0)
        }
        #expect(parsedLength < source.utf16.count * 3)
    }

    @Test func formattedSelectionProjectsBackToMarkdownAndPartialWords() throws {
        let source = "🐉 **bold** and [site](https://example.invalid)"
        let nodes = flatten(ChatMarkdownDocument(source).blocks)
        let strong = try #require(nodes.first { $0.kind == .strong })
        let word = try #require(strong.children.first?.sourceRange)
        let mappings = [
            ChatSourceSpan(rendered: NSRange(location: 3, length: 4), source: word, exact: true),
            ChatSourceSpan(rendered: NSRange(location: 3, length: 4), source: try #require(strong.sourceRange), exact: false)
        ]
        func selected(_ range: NSRange) -> String? {
            ChatSourceSelection.markdown(source: source, renderedLength: 16, mappings: mappings, selection: range)
        }
        #expect(selected(NSRange(location: 3, length: 4)) == "**bold**")
        #expect(selected(NSRange(location: 4, length: 2)) == "ol")
        #expect(selected(NSRange(location: NSNotFound, length: 1)) == nil)
        #expect(selected(NSRange(location: 0, length: Int.max)) == nil)
        #expect(AgentConversationText.quote(source, selection: selected(NSRange(location: 3, length: 4))) == "> **bold**")
    }

    @Test func selectionsAroundDecodedEntitiesAndEscapesKeepTheirSource() {
        let source = #"Fish &amp; chips \*literal\* &#x3b1;"#, rendered = "Fish & chips *literal* α"
        let mappings = ChatSourceSelection.inlineSpans(source: source, rendered: rendered, sourceOffset: 0, renderedOffset: 0)
        func selected(_ value: String) -> String? {
            ChatSourceSelection.markdown(source: source, renderedLength: rendered.utf16.count, mappings: mappings,
                selection: (rendered as NSString).range(of: value))
        }
        #expect(selected("chips") == "chips")
        #expect(selected("&") == "&amp;")
        #expect(selected("α") == "&#x3b1;")
        #expect(selected("*literal*") == #"\*literal\*"#)
    }
}

@MainActor @Suite(.timeLimit(.minutes(2))) struct ChatRichTextTests {
    func renderer(_ source: String) -> ChatRichTextRenderer {
        let renderer = ChatRichTextRenderer(); renderer.update(source); return renderer
    }
    func attributes(_ renderer: ChatRichTextRenderer, containing value: String) -> [NSAttributedString.Key: Any] {
        let range = (renderer.text.string as NSString).range(of: value)
        guard range.location != NSNotFound else { Issue.record("Missing rendered text: \(value)"); return [:] }
        return renderer.text.attributes(at: range.location, effectiveRange: nil)
    }

    @Test func commonMarkAndGFMProduceNativeFormatting() throws {
        let source = """
        # Heading

        **bold** *italic* ~~gone~~ `code` [link](https://example.invalid)

        3. third
        4. fourth
           - nested

        - [x] done
        - [ ] todo

        > quoted

        ---

        ![image label](https://example.invalid/image.png)
        """
        let value = renderer(source)
        #expect(value.text.string.contains("3. third"))
        #expect(value.text.string.contains("4. fourth"))
        #expect(value.text.string.contains("• nested"))
        #expect(value.text.string.contains("☑ done"))
        #expect(value.text.string.contains("☐ todo"))
        #expect(attributes(value, containing: "Heading")[.chatBlockKind] as? String == "heading")
        let bold = try #require(attributes(value, containing: "bold")[.font] as? NSFont)
        #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        let italic = try #require(attributes(value, containing: "italic")[.font] as? NSFont)
        #expect(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        #expect(attributes(value, containing: "gone")[.strikethroughStyle] as? Int == 1)
        #expect(attributes(value, containing: "code")[.backgroundColor] != nil)
        #expect(attributes(value, containing: "link")[.link] as? URL == URL(string: "https://example.invalid"))
        #expect(attributes(value, containing: "quoted")[.chatBlockKind] as? String == "blockquote")
        #expect(attributes(value, containing: "────")[.chatBlockKind] as? String == "rule")
        #expect(attributes(value, containing: "image label")[.link] != nil)
        #expect(attributes(value, containing: "image label")[.attachment] == nil)
    }

    @Test func linksIncludeBareAutolinksAndInlineCodeAndRejectOtherSchemes() {
        let source = """
        [Open docs](https://example.invalid/docs), https://example.invalid/plain, <https://example.invalid/angle>,
        `https://example.invalid/code`, <mailto:person@example.invalid>,
        [blocked](javascript:alert%281%29), [read](file:///example.txt), [app](example-app://open).
        """
        let value = renderer(source)
        #expect(value.text.string.contains("Open docs (example.invalid)"))
        for suffix in ["docs", "plain", "angle", "code"] {
            let label = suffix == "docs" ? "Open docs" : "https://example.invalid/\(suffix)"
            #expect(attributes(value, containing: label)[.link] as? URL == URL(string: "https://example.invalid/\(suffix)"))
        }
        #expect(attributes(value, containing: "person@example.invalid")[.link] as? URL == URL(string: "mailto:person@example.invalid"))
        for label in ["blocked", "read", "app"] {
            #expect(attributes(value, containing: label)[.link] == nil)
        }
    }

    @Test func projectReferencesCannotEscapeAndOnlyLocalRasterImagesBecomeAttachments() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("project", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Example.swift")
        try Data().write(to: file)
        let image = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGMQrrwLRww4OQBAuBDtANwBaQAAAABJRU5ErkJggg=="))
        try image.write(to: root.appendingPathComponent("plot.png"))
        try image.write(to: temporary.appendingPathComponent("private.png"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("escape.png"),
                                      withDestinationURL: temporary.appendingPathComponent("private.png"))
        try Data("not an image".utf8).write(to: root.appendingPathComponent("broken.png"))
        let scope = ChatResourceScope(directories: [root])
        #expect(scope.fileURL("../private.png") == nil)
        #expect(scope.fileURL("escape.png") == nil)
        #expect(scope.fileURL(file.absoluteString) == nil)
        let source = """
        See `Example.swift:42` or [the source](Example.swift).

        ![Local plot](plot.png)

        ![Escaped image](escape.png)

        ![Broken image](broken.png)

        ![Remote image](https://example.invalid/plot.png)
        """
        let resolvedFile = try #require(scope.fileURL("Example.swift"))
        let images = scope.localImages(in: source)
        #expect(Set(images.keys) == ["plot.png"])
        let value = ChatRichTextRenderer()
        value.update(source, resourceScope: scope, images: images)
        #expect(attributes(value, containing: "Example.swift:42")[.link] as? URL == resolvedFile)
        #expect(attributes(value, containing: "the source")[.link] as? URL == resolvedFile)
        #expect(attributes(value, containing: "Escaped image")[.link] == nil)
        #expect(attributes(value, containing: "Broken image")[.attachment] == nil)
        #expect(attributes(value, containing: "Remote image")[.attachment] == nil)
        let range = (value.text.string as NSString).range(of: "\u{fffc}")
        #expect(range.location != NSNotFound)
        if range.location != NSNotFound {
            #expect(value.markdown(for: range) == "![Local plot](plot.png)")
        }
    }

    @Test func chartsRenderAfterStreamingAndMalformedChartsStayReadable() {
        let spec = #"{"title":"Count","values":[{"label":"A","value":2},{"label":"B","value":-1}]}"#
        let source = "```chart\n" + spec + "\n```"
        let value = ChatRichTextRenderer()
        value.update(source, figuresEnabled: false)
        #expect(value.text.string.contains(spec))
        value.update(source)
        let range = (value.text.string as NSString).range(of: "\u{fffc}")
        #expect(range.location != NSNotFound)
        if range.location != NSNotFound {
            #expect(value.markdown(for: range) == source)
        }
        value.update("```chart\n{}\n```")
        #expect(value.text.string.contains("{}"))
        #expect(value.codeBlocks.count == 1)
        value.update("```chart\n" + spec)
        #expect(value.text.string.contains("```chart"))
    }

    @Test func tablesAndFencesAreStructuredAndHTMLCannotLoadResources() throws {
        let value = renderer("| Left | Right |\n| :--- | ---: |\n| one | two |\n\n```swift\nlet x = \"$literal$\"\n```\n\n<img src=\"https://example.invalid/a.png\">")
        let paragraph = try #require(attributes(value, containing: "one")[.paragraphStyle] as? NSParagraphStyle)
        #expect(paragraph.textBlocks.first is NSTextTableBlock)
        let right = try #require(attributes(value, containing: "two")[.paragraphStyle] as? NSParagraphStyle)
        #expect(right.alignment == .right)
        #expect(value.codeBlocks.count == 1)
        #expect(value.codeBlocks.first?.language == "swift")
        #expect(value.codeBlocks.first?.code == "let x = \"$literal$\"\n")
        #expect(value.text.string.contains("<img src="))
        #expect(attributes(value, containing: "$literal$")[.attachment] == nil)
    }

    @Test func mathUsesBaselineAttachmentsAndErrorsKeepTheSource() throws {
        let value = renderer(#"Inline $e^{i\pi}+1=0$ and \(x^2\)."# + "\n\n" + #"$$\int_0^1 x\,dx$$"#)
        var attachments: [NSTextAttachment] = []
        value.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.text.length)) { attribute, _, _ in
            if let attachment = attribute as? NSTextAttachment { attachments.append(attachment) }
        }
        #expect(attachments.count == 3)
        #expect(attachments.allSatisfy { $0.bounds.height > 0 && $0.bounds.origin.y <= 0 })
        for source in [#"$\definitelyUnknownCommand{x}$"#, #"$$\frac{1}{"#, "```swift\nlet unfinished = **plain**"] {
            let output = renderer(source)
            #expect(output.text.string.trimmingCharacters(in: .newlines) == source)
        }
        let currency = renderer("costs $5 and $10")
        #expect(currency.text.string.trimmingCharacters(in: .newlines) == "costs $5 and $10")
    }

    @Test func sourceSelectionRetainsMarkdownAndHandlesUnicodeAndPartialWords() {
        let source = #"🐉 **bold** and [site](https://example.invalid) plus `code` and $x^2$"#
        let value = renderer(source), visible = value.text.string as NSString
        #expect(value.markdown(for: visible.range(of: "bold")) == "**bold**")
        #expect(value.markdown(for: visible.range(of: "ol")) == "ol")
        #expect(value.markdown(for: visible.range(of: "site")) == "[site](https://example.invalid)")
        #expect(value.markdown(for: visible.range(of: "code")) == "`code`")
        #expect(value.markdown(for: visible.range(of: "\u{fffc}")) == "$x^2$")
        #expect(value.markdown(for: NSRange(location: 0, length: visible.length)) == source)
        #expect(value.markdown(for: NSRange(location: 0, length: 0)) == nil)
        #expect(value.markdown(for: NSRange(location: 999, length: 1)) == nil)
        #expect(AgentConversationText.quote(source, selection: value.markdown(for: visible.range(of: "bold"))) == "> **bold**")
    }

    @Test func streamingOnlyReplacesTheOpenTailAndConvergesWithOneShot() {
        let value = renderer("First **bold**.\n\nSecond")
        let prefix = value.text.attributedSubstring(from: NSRange(location: 0, length: "First bold.\n".utf16.count))
        value.update("First **bold**.\n\nSecond with `code`\n\n```swift\nlet x")
        #expect(value.reparsedSourceRange.location == "First **bold**.\n\n".utf16.count)
        #expect(value.text.attributedSubstring(from: NSRange(location: 0, length: prefix.length)) == prefix)
        #expect(value.text.string.contains("```swift\nlet x"))
        let final = "First **bold**.\n\nSecond with `code`\n\n```swift\nlet x = 1\n```\n\nDone $x^2$"
        value.update(final)
        let oneShot = renderer(final)
        #expect(value.text.string == oneShot.text.string)
        #expect(value.codeBlocks.count == 1)
        #expect(value.markdown(for: (value.text.string as NSString).range(of: "bold")) == "**bold**")
        #expect(!value.update(final))
        value.update("Replaced")
        #expect(value.reparsedSourceRange.location == 0)
        #expect(value.text.string == "Replaced\n")
    }

    @Test func streamingTableListMathAndReferenceLinksConverge() {
        let samples = [
            "Title\n===\n\n- one\n  - nested\n\nnext",
            "| A | B |\n| --- | --- |\n| one | two |\n\nnext",
            #"Math \[\int_0^1 x dx\] done"#,
            "Before\n\n$$\\int_0^1\n\nx dx$$\n\nAfter",
            "[link][ref]\n\nNext\n\n[ref]: https://example.invalid"
        ]
        for source in samples {
            let value = ChatRichTextRenderer()
            var partial = ""
            for character in source { partial.append(character); value.update(partial) }
            #expect(value.text.string == renderer(source).text.string, "\(source)")
        }
    }

    @Test(arguments: [false, true])
    func indentedCodeLaysOutEachLineInItsOwnFragment(dark: Bool) throws {
        let view = ChatMessageTextView(frame: .zero, textContainer: nil)
        view.appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        view.update("    first line\n    second line\n    third line")
        for width: CGFloat in [60, 350] {
            let size = view.measuredSize(width: width)
            let layout = try #require(view.layoutManager)
            let text = try #require(view.textStorage?.string) as NSString
            let lines = ["first line", "second line", "third line"]
            let rectangles = lines.map {
                let glyph = layout.glyphIndexForCharacter(at: text.range(of: $0).location)
                return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            #expect(rectangles[0].maxY <= rectangles[1].minY)
            #expect(rectangles[1].maxY <= rectangles[2].minY)
            #expect(rectangles[2].maxY <= size.height)
        }
    }

    @Test func nativeMeasurementUsesProposedTranscriptWidth() {
        let view = ChatMessageTextView(frame: .zero, textContainer: nil)
        view.update(String(repeating: "Long prose with **formatting**. ", count: 25) + "\n\n```\n" + String(repeating: "code", count: 100) + "\n```")
        let wide = view.measuredSize(width: 700), narrow = view.measuredSize(width: 350)
        #expect(wide.width == 700)
        #expect(narrow.width == 350)
        #expect(narrow.height > wide.height)
    }
}
