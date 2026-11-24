import AppKit
import CoreText
import SwiftUI
import AitvarasAgents

/// The editor stores Markdown source. TextKit only changes its presentation,
/// keeping selection, clipboard, undo and the provider payload in source offsets.
struct ComposerMarkdownEditor: NSViewRepresentable {
    let text: String
    let enabled: Bool
    let focusRequest: UUID?
    let hint: String?
    let change: (String) -> Void
    let measure: (CGFloat) -> Void
    let onReturn: (NSEvent.ModifierFlags, Bool) -> Bool
    let onPaste: (NSPasteboard) -> Bool

    func makeNSView(context: Context) -> ComposerEditorScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 2
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let editor = ComposerSourceTextView(frame: .zero, textContainer: container)
        editor.configure()
        let scroll = ComposerEditorScrollView(editor: editor, storage: storage)
        scroll.configure()
        return scroll
    }

    func updateNSView(_ scroll: ComposerEditorScrollView, context: Context) {
        let editor = scroll.editor
        editor.onChange = change
        editor.onReturn = onReturn
        editor.onPaste = onPaste
        scroll.onMeasure = measure
        editor.isEditable = enabled
        editor.setAccessibilityEnabled(enabled)
        editor.setAccessibilityHelp(hint)
        editor.placeholder = hint ?? "Message"

        scroll.applyExternalText(text, focusRequest: enabled ? focusRequest : nil)
    }
}

final class ComposerEditorScrollView: NSScrollView {
    let editor: ComposerSourceTextView
    private let storage: NSTextStorage
    var onMeasure: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat?
    private var appliedFocus: UUID?

    init(editor: ComposerSourceTextView, storage: NSTextStorage) {
        self.editor = editor
        self.storage = storage
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    func configure() {
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = editor
        editor.onLayoutChange = { [weak self] in self?.reportContentHeight() }
    }

    func applyExternalText(_ value: String, focusRequest: UUID?) {
        if !editor.string.utf8.elementsEqual(value.utf8), !editor.hasMarkedText() {
            editor.undoManager?.removeAllActions(withTarget: editor)
            editor.string = value
            editor.setSelectedRange(AgentComposerCaret.afterInsertion(value))
            editor.refreshMarkdown()
            editor.needsDisplay = true
        }
        if let focusRequest, focusRequest != appliedFocus, window != nil {
            appliedFocus = focusRequest
            Task { @MainActor [weak self] in
                guard let self, let window, appliedFocus == focusRequest, editor.isEditable else { return }
                window.makeFirstResponder(editor)
                editor.setSelectedRange(AgentComposerCaret.afterInsertion(editor.string))
                editor.scrollRangeToVisible(editor.selectedRange())
            }
        }
        reportContentHeight()
    }

    override func layout() {
        super.layout()
        if contentSize.width > 1, abs(editor.frame.width - contentSize.width) > 0.5 {
            editor.setFrameSize(NSSize(width: contentSize.width, height: max(editor.frame.height, contentSize.height)))
        }
        reportContentHeight()
    }

    private func reportContentHeight() {
        guard contentSize.width > 1, let layout = editor.layoutManager,
              let container = editor.textContainer else { return }
        layout.ensureLayout(for: container)
        let end = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let height = ceil(end + editor.textContainerInset.height * 2)
        guard reportedHeight != height else { return }
        reportedHeight = height
        Task { @MainActor [weak self] in
            guard let self, reportedHeight == height else { return }
            onMeasure?(height)
        }
    }
}

final class ComposerSourceTextView: NSTextView, @preconcurrency NSLayoutManagerDelegate {
    private static let bullet = NSAttributedString.Key("Aitvaras.ComposerBullet")
    private static let hidden = NSAttributedString.Key("Aitvaras.ComposerHidden")
    private let bodyFont = NSFont.systemFont(ofSize: 13)
    private var applyingStyles = false
    private var activeLine: NSRange?
    private var markdown = ComposerMarkdown()
    var onChange: ((String) -> Void)?
    var onLayoutChange: (() -> Void)?
    var onReturn: ((NSEvent.ModifierFlags, Bool) -> Bool)?
    var onPaste: ((NSPasteboard) -> Bool)?
    var placeholder = "Message" { didSet { if oldValue != placeholder { needsDisplay = true } } }

    func configure() {
        isRichText = false
        importsGraphics = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        allowsUndo = true
        drawsBackground = false
        textContainerInset = NSSize(width: 0, height: 3)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        layoutManager?.delegate = self
        font = bodyFont
        setAccessibilityIdentifier("chat.composer.input")
        setAccessibilityLabel("Message")
    }

    override func didChangeText() {
        refreshMarkdown()
        super.didChangeText()
        onChange?(string)
        needsDisplay = true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting, !applyingStyles, !hasMarkedText(), markdown.source.utf8.elementsEqual(string.utf8), activeLine != currentLine {
            applyStyles()
        }
    }

    private var currentLine: NSRange? {
        guard !string.isEmpty else { return nil }
        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        return source.lineRange(for: NSRange(location: caret, length: 0))
    }

    func refreshMarkdown() {
        guard !hasMarkedText(), !applyingStyles else { return }
        markdown = ComposerMarkdown(string)
        applyStyles()
    }

    private func applyStyles() {
        guard !applyingStyles, let storage = textStorage else { return }
        applyingStyles = true
        defer { applyingStyles = false }
        activeLine = currentLine
        let base: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.labelColor]
        if storage.length > 0 {
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
            for span in markdown.spans {
                switch span.style {
                case .heading(let level):
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: max(14, 20 - CGFloat(level)), weight: .semibold), range: span.range)
                case .strong, .emphasis:
                    storage.enumerateAttribute(.font, in: span.range) { value, range, _ in
                        let font = value as? NSFont ?? bodyFont
                        let trait: NSFontTraitMask = span.style == .strong ? .boldFontMask : .italicFontMask
                        storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: range)
                    }
                case .code:
                    storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                           .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.09)], range: span.range)
                case .quote:
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
                case .link:
                    storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: span.range)
                case .strike:
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
                case .syntax:
                    if let activeLine, NSIntersectionRange(activeLine, span.range).length > 0 {
                        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
                    } else {
                        storage.addAttribute(Self.hidden, value: true, range: span.range)
                    }
                case .bullet, .ordered:
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
                    if span.style == .bullet { storage.addAttribute(Self.bullet, value: true, range: span.range) }
                }
            }
            storage.endEditing()
            layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length),
                                             changeInLength: 0, actualCharacterRange: nil)
        }
        typingAttributes = base
        onLayoutChange?()
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        let indices = 0..<glyphRange.length
        guard indices.contains(where: {
            let index = characterIndexes[$0]
            return index < storage.length && (storage.attribute(Self.hidden, at: index, effectiveRange: nil) != nil ||
                storage.attribute(Self.bullet, at: index, effectiveRange: nil) != nil)
        }) else { return 0 }
        var glyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var properties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var bulletCharacter: UniChar = 0x2022
        var bulletGlyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font as CTFont, &bulletCharacter, &bulletGlyph, 1)
        for offset in indices where characterIndexes[offset] < storage.length {
            let index = characterIndexes[offset]
            if storage.attribute(Self.hidden, at: index, effectiveRange: nil) != nil {
                properties[offset].insert(.null)
            } else if bulletGlyph != 0, storage.attribute(Self.bullet, at: index, effectiveRange: nil) != nil {
                glyphs[offset] = bulletGlyph
            }
        }
        layoutManager.setGlyphs(glyphs, properties: properties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command),
           !hasMarkedText(), onReturn?(event.modifierFlags, false) == true { return }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if ["insertNewline:", "insertNewlineIgnoringFieldEditor:"].contains(NSStringFromSelector(selector)), !hasMarkedText() {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            let edit = markdown.newlineEdit(at: selectedRange())
            if onReturn?(flags, edit != nil) == true { return }
            if let replacement = edit {
                insertText(replacement.text, replacementRange: replacement.range)
                return
            }
        }
        super.doCommand(by: selector)
    }

    override func paste(_ sender: Any?) {
        guard !hasMarkedText(), onPaste?(.general) == true else {
            super.pasteAsPlainText(sender)
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: 2, y: textContainerInset.height + 1),
                withAttributes: [.font: bodyFont, .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}
