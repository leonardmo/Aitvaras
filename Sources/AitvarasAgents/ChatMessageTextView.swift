import AppKit

/// A single selectable TextKit surface. Code stays in the same text storage;
/// horizontal scrolling changes its paragraph indents, not its characters or
/// selection coordinates. Prose remains constrained to the transcript width.
@MainActor public final class ChatMessageTextView: NSTextView, NSTextViewDelegate {
    public let renderer = ChatRichTextRenderer()
    public var quote: ((String?) -> Void)?
    public var fork: (() -> Void)?
    public var forkEnabled = false
    public var edit: (() -> Void)?
    private var viewportWidth: CGFloat = 0
    private var offsets: [Int: CGFloat] = [:]
    private var codeWidths: [Int: CGFloat] = [:]
    private var controls: [Int: (NSButton, NSScroller)] = [:]

    /// `NSTextView(frame:textContainer: nil)` creates no text system at all,
    /// so build a TextKit 1 stack here. The view must own the storage: layout
    /// managers and containers only reference it weakly.
    private var ownedStorage: NSTextStorage?

    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        var storage: NSTextStorage?
        var resolved = container
        if resolved == nil {
            let newStorage = NSTextStorage(), layout = NSLayoutManager()
            newStorage.addLayoutManager(layout)
            let newContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            layout.addTextContainer(newContainer)
            storage = newStorage; resolved = newContainer
        }
        super.init(frame: frameRect, textContainer: resolved)
        ownedStorage = storage
        isEditable = false; isSelectable = true; isRichText = true
        drawsBackground = false; textContainerInset = .zero
        clipsToBounds = true
        textContainer?.lineFragmentPadding = 0; textContainer?.widthTracksTextView = false
        isVerticallyResizable = true; isHorizontallyResizable = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        delegate = self
    }
    public required init?(coder: NSCoder) { fatalError("Use init(frame:textContainer:)") }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    public func update(_ source: String) {
        let name = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard renderer.update(source, appearance: name), let storage = textStorage else { return }
            let replacement = renderer.replacedRenderedRange
            let selection = selectedRange()
            storage.replaceCharacters(in: replacement, with: renderer.text.attributedSubstring(
                from: NSRange(location: replacement.location, length: renderer.text.length - replacement.location)))
            setSelectedRange(NSRange(location: min(selection.location, storage.length), length: min(selection.length, max(0, storage.length - selection.location))))
            codeWidths = codeWidths.filter { $0.key < replacement.location }
            for block in renderer.codeBlocks where block.range.location >= replacement.location {
                let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                codeWidths[block.range.location] = block.code.components(separatedBy: "\n").map {
                    ($0 as NSString).size(withAttributes: [.font: font]).width + 20
                }.max() ?? 0
            }
            constrainParagraphs(in: NSRange(location: replacement.location, length: storage.length - replacement.location))
            invalidateIntrinsicContentSize()
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update(renderer.source)
    }

    public override func draw(_ dirtyRect: NSRect) {
        if let layout = layoutManager, let container = textContainer {
            for block in renderer.codeBlocks {
                let glyphs = layout.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
                let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
                let panel = NSRect(x: 0, y: bounds.minY, width: viewportWidth, height: bounds.height)
                if panel.intersects(dirtyRect) {
                    NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
                    NSBezierPath(roundedRect: panel, xRadius: 6, yRadius: 6).fill()
                }
            }
        }
        super.draw(dirtyRect)
    }

    public func measuredSize(width: CGFloat) -> NSSize {
        if viewportWidth != width {
            viewportWidth = width
            constrainParagraphs()
        }
        guard let layout = layoutManager, let container = textContainer else { return NSSize(width: width, height: 20) }
        layout.ensureLayout(for: container)
        return NSSize(width: width, height: max(20, ceil(layout.usedRect(for: container).maxY)))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0, viewportWidth != newSize.width {
            viewportWidth = newSize.width
            constrainParagraphs()
        }
        positionCodeControls()
    }

    private func codeWidth(_ block: ChatCodeBlock) -> CGFloat {
        max(viewportWidth, codeWidths[block.range.location] ?? 0)
    }

    private func constrainParagraphs(in requested: NSRange? = nil) {
        guard viewportWidth > 0, let storage = textStorage, let container = textContainer else { return }
        let maxWidth = renderer.codeBlocks.map(codeWidth).max() ?? viewportWidth
        container.containerSize = NSSize(width: max(viewportWidth, maxWidth), height: .greatestFiniteMagnitude)
        storage.beginEditing()
        let characters = storage.string as NSString
        let requested = requested ?? NSRange(location: 0, length: storage.length)
        var cursor = requested.location
        while cursor < NSMaxRange(requested) {
            let range = characters.paragraphRange(for: NSRange(location: cursor, length: 0))
            cursor = NSMaxRange(range)
            guard let original = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let style = original.mutableCopy() as? NSMutableParagraphStyle else { continue }
            // Table cells constrain their own width to the transcript, even if
            // another code block widens the underlying text container.
            for block in style.textBlocks {
                if let cell = block as? NSTextTableBlock {
                    cell.table.setValue(viewportWidth, type: .absoluteValueType, for: .width)
                }
            }
            if let block = renderer.codeBlocks.first(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                let offset = offsets[block.range.location] ?? 0
                style.headIndent = 8 - offset; style.firstLineHeadIndent = 8 - offset
                style.tailIndent = codeWidth(block) - offset
                // Keep TextKit's regular line fragments for multiline code.
                // The container is widened for the code; the view clips the viewport.
                style.lineBreakMode = .byCharWrapping
                if let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
                   let layout = layoutManager {
                    style.minimumLineHeight = ceil(layout.defaultLineHeight(for: font))
                }
                // Header and footer must not move with the code contents.
                if NSIntersectionRange(block.contentRange, range).length == 0 {
                    style.headIndent = 8; style.firstLineHeadIndent = 8; style.tailIndent = viewportWidth
                }
            } else { style.tailIndent = max(style.headIndent + 1, viewportWidth) }
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        storage.endEditing()
        positionCodeControls()
    }

    private func positionCodeControls() {
        guard viewportWidth > 0, let layout = layoutManager, let container = textContainer else { return }
        let active = Set(renderer.codeBlocks.map { $0.range.location })
        for id in Array(controls.keys) where !active.contains(id) {
            controls[id]?.0.removeFromSuperview(); controls[id]?.1.removeFromSuperview(); controls.removeValue(forKey: id)
            offsets.removeValue(forKey: id)
        }
        layout.ensureLayout(for: container)
        for block in renderer.codeBlocks {
            let id = block.range.location
            let pair: (NSButton, NSScroller)
            if let existing = controls[id] { pair = existing }
            else {
                let copy = NSButton(title: "Copy", target: self, action: #selector(copyCode(_:)))
                copy.bezelStyle = .inline; copy.controlSize = .small; copy.tag = id
                copy.setAccessibilityLabel("Copy code")
                let scroller = NSScroller()
                scroller.scrollerStyle = .legacy; scroller.controlSize = .small
                scroller.target = self; scroller.action = #selector(scrollCode(_:)); scroller.tag = id
                addSubview(copy); addSubview(scroller); pair = (copy, scroller); controls[id] = pair
            }
            let glyphs = layout.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            pair.0.frame = NSRect(x: max(0, viewportWidth - 52), y: rect.minY, width: 48, height: 18)
            let extent = max(0, codeWidth(block) - viewportWidth)
            pair.1.isHidden = extent < 1
            pair.1.frame = NSRect(x: 4, y: max(rect.minY, rect.maxY - 14), width: max(0, viewportWidth - 8), height: 12)
            pair.1.knobProportion = min(1, viewportWidth / max(1, codeWidth(block)))
            pair.1.doubleValue = extent > 0 ? Double((offsets[id] ?? 0) / extent) : 0
        }
    }

    @objc private func copyCode(_ sender: NSButton) {
        guard let block = renderer.codeBlocks.first(where: { $0.range.location == sender.tag }) else { return }
        copyString(block.code)
    }
    @objc private func scrollCode(_ sender: NSScroller) {
        guard let block = renderer.codeBlocks.first(where: { $0.range.location == sender.tag }) else { return }
        let extent = max(0, codeWidth(block) - viewportWidth)
        var offset = offsets[sender.tag] ?? 0
        switch sender.hitPart {
        case .decrementLine: offset -= 24
        case .incrementLine: offset += 24
        case .decrementPage: offset -= viewportWidth * 0.8
        case .incrementPage: offset += viewportWidth * 0.8
        default: offset = CGFloat(sender.doubleValue) * extent
        }
        offsets[sender.tag] = min(extent, max(0, offset)); constrainParagraphs(); needsDisplay = true
    }

    public override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), let layout = layoutManager, let container = textContainer {
            let point = convert(event.locationInWindow, from: nil)
            if let block = renderer.codeBlocks.first(where: {
                let glyphs = layout.glyphRange(forCharacterRange: $0.range, actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                return point.y >= rect.minY && point.y <= rect.maxY
            }) {
                let id = block.range.location, extent = max(0, codeWidth(block) - viewportWidth)
                offsets[id] = min(extent, max(0, (offsets[id] ?? 0) - event.scrollingDeltaX))
                constrainParagraphs(); needsDisplay = true; return
            }
        }
        super.scrollWheel(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, enabled: Bool = true) {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: "")
            value.target = self; value.isEnabled = enabled; menu.addItem(value)
        }
        item("Copy", #selector(copy(_:)))
        if quote != nil { item("Reply with quote", #selector(replyWithQuote(_:))) }
        if fork != nil { item("Fork from here", #selector(forkFromHere(_:)), enabled: forkEnabled) }
        if edit != nil { item("Edit & resend", #selector(editMessage(_:))) }
        return menu
    }
    private func copyString(_ value: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    public override func copy(_ sender: Any?) { copyString(renderer.markdown(for: selectedRange()) ?? renderer.source) }
    @objc private func replyWithQuote(_ sender: Any?) { quote?(renderer.markdown(for: selectedRange())) }
    @objc private func forkFromHere(_ sender: Any?) { if forkEnabled { fork?() } }
    @objc private func editMessage(_ sender: Any?) { edit?() }
    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return true }
        NSWorkspace.shared.open(url); return true
    }
}
