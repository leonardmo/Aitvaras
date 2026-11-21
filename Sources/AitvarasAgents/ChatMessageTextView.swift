import AppKit
import UniformTypeIdentifiers

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
    private var scope = ChatResourceScope()
    private var images: [String: CGImage] = [:]
    private var figuresEnabled = true
    private var pointerTracking: NSTrackingArea?
    private var figurePreview: NSPopover?
    private var offsets: [Int: CGFloat] = [:]
    private var codeWidths: [Int: CGFloat] = [:]
    private var controls: [Int: (NSButton, NSScroller)] = [:]
    /// Heights measured off-screen for widths other than the live one, so
    /// SwiftUI's repeated proposals are answered without relayout.
    private var measuredHeights: [CGFloat: CGFloat] = [:]

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
        // SwiftUI owns the frame. A self-resizing text view fights it.
        isVerticallyResizable = false; isHorizontallyResizable = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        delegate = self
    }
    public required init?(coder: NSCoder) { fatalError("Use init(frame:textContainer:)") }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    public func update(_ source: String, resourceScope: ChatResourceScope = .init(),
                       images: [String: CGImage] = [:], figuresEnabled: Bool = true) {
        scope = resourceScope
        self.images = images
        self.figuresEnabled = figuresEnabled
        refresh(source)
    }

    private func refresh(_ source: String) {
        let name = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard renderer.update(source, appearance: name, resourceScope: scope, images: images,
                                  figuresEnabled: figuresEnabled), let storage = textStorage else { return }
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
            measuredHeights.removeAll()
            constrainParagraphs(in: NSRange(location: replacement.location, length: storage.length - replacement.location))
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(renderer.source)
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

    /// Must leave the displayed view untouched: SwiftUI calls this during its
    /// layout pass, often with widths that differ from the frame it then
    /// applies. Reflowing the live storage here re-dirties the window's layout
    /// on every pass, which AppKit ends by crashing the app.
    public func measuredSize(width: CGFloat) -> NSSize {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else {
            return NSSize(width: width, height: 20)
        }
        if viewportWidth == 0 {
            // Not on screen yet; adopting the first proposal is free.
            viewportWidth = width
            constrainParagraphs()
        }
        if width == viewportWidth {
            layout.ensureLayout(for: container)
            return NSSize(width: width, height: max(20, ceil(layout.usedRect(for: container).maxY)))
        }
        if let height = measuredHeights[width] { return NSSize(width: width, height: height) }
        let scratchStorage = NSTextStorage(attributedString: storage)
        let scratchLayout = NSLayoutManager()
        scratchStorage.addLayoutManager(scratchLayout)
        let scratchContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        scratchContainer.lineFragmentPadding = 0
        scratchLayout.addTextContainer(scratchContainer)
        // Tables are shared with the live storage; restore their widths after.
        let tables = applyParagraphStyles(width: width, to: scratchStorage, container: scratchContainer, layout: scratchLayout)
        scratchLayout.ensureLayout(for: scratchContainer)
        let height = max(20, ceil(scratchLayout.usedRect(for: scratchContainer).maxY))
        for (table, value, type) in tables { table.setValue(value, type: type, for: .width) }
        measuredHeights[width] = height
        return NSSize(width: width, height: height)
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
        codeWidth(block, viewport: viewportWidth)
    }

    private func codeWidth(_ block: ChatCodeBlock, viewport: CGFloat) -> CGFloat {
        max(viewport, codeWidths[block.range.location] ?? 0)
    }

    private func constrainParagraphs(in requested: NSRange? = nil) {
        guard viewportWidth > 0, let storage = textStorage, let container = textContainer,
              let layout = layoutManager else { return }
        _ = applyParagraphStyles(width: viewportWidth, to: storage, container: container, layout: layout, in: requested)
        positionCodeControls()
    }

    /// Fits `storage` to `width` and returns each table's previous width.
    @discardableResult
    private func applyParagraphStyles(width viewportWidth: CGFloat, to storage: NSTextStorage,
                                      container: NSTextContainer, layout: NSLayoutManager,
                                      in requested: NSRange? = nil) -> [(NSTextTable, CGFloat, NSTextBlock.ValueType)] {
        func codeWidth(_ block: ChatCodeBlock) -> CGFloat { self.codeWidth(block, viewport: viewportWidth) }
        var tables: [(NSTextTable, CGFloat, NSTextBlock.ValueType)] = []
        var seen = Set<ObjectIdentifier>()
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
                    if seen.insert(ObjectIdentifier(cell.table)).inserted {
                        tables.append((cell.table, cell.table.value(for: .width), cell.table.valueType(for: .width)))
                    }
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
                if let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                    style.minimumLineHeight = ceil(layout.defaultLineHeight(for: font))
                }
                // Header and footer must not move with the code contents.
                if NSIntersectionRange(block.contentRange, range).length == 0 {
                    style.headIndent = 8; style.firstLineHeadIndent = 8; style.tailIndent = viewportWidth
                }
            } else {
                let kind = storage.attribute(.chatBlockKind, at: range.location, effectiveRange: nil) as? String
                let wide = !style.textBlocks.isEmpty || kind == "figure"
                style.tailIndent = max(style.headIndent + 1, wide ? viewportWidth : min(620, viewportWidth))
            }
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        storage.endEditing()
        return tables
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

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
    }

    private func character(at event: NSEvent) -> Int? {
        guard let textStorage, textStorage.length > 0, let layoutManager, let textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let location = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(location)
        else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    private func link(at event: NSEvent) -> URL? {
        guard let index = character(at: event) else { return nil }
        return textStorage?.attribute(.link, at: index, effectiveRange: nil) as? URL
    }

    private func figure(at event: NSEvent) -> ChatFigureCell? {
        guard let index = character(at: event),
              let attachment = textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment
        else { return nil }
        return attachment.attachmentCell as? ChatFigureCell
    }

    public override func mouseMoved(with event: NSEvent) {
        if let url = link(at: event) {
            let destination = url.isFileURL ? url.path : url.absoluteString
            if toolTip != destination { toolTip = destination }
            NSCursor.pointingHand.set()
        } else {
            let caption = figure(at: event)?.caption
            if toolTip != caption { toolTip = caption }
            super.mouseMoved(with: event)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        toolTip = nil
        super.mouseExited(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, object: Any? = nil, enabled: Bool = true) {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: "")
            value.target = self; value.isEnabled = enabled; value.representedObject = object; menu.addItem(value)
        }
        if let url = link(at: event) {
            item(url.isFileURL ? "Show in Finder" : "Open Link", #selector(openLink(_:)), object: url)
            item("Copy Link", #selector(copyLink(_:)), object: url)
            menu.addItem(.separator())
        }
        if let figure = figure(at: event) {
            item("View Figure", #selector(viewFigure(_:)), object: figure)
            item("Copy Image", #selector(copyFigure(_:)), object: figure)
            item("Save as PNG…", #selector(saveFigure(_:)), object: figure)
            item("Copy Source", #selector(copyFigureSource(_:)), object: figure)
            menu.addItem(.separator())
        }
        item("Copy", #selector(copy(_:)))
        if quote != nil { item("Reply with quote", #selector(replyWithQuote(_:))) }
        if fork != nil { item("Fork from here", #selector(forkFromHere(_:)), enabled: forkEnabled) }
        if edit != nil { item("Edit & resend", #selector(editMessage(_:))) }
        return menu
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { activateLink(url) }
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { copyString(url.isFileURL ? url.path : url.absoluteString) }
    }

    @objc private func viewFigure(_ sender: NSMenuItem) {
        guard let figure = sender.representedObject as? ChatFigureCell, let image = figure.image else { return }
        let preview = NSPopover()
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel(figure.caption)
        let controller = NSViewController()
        controller.view = view
        let limit = window?.contentView?.bounds.size ?? NSSize(width: 700, height: 500)
        preview.contentSize = NSSize(width: min(720, limit.width * 0.9), height: min(540, limit.height * 0.8))
        preview.contentViewController = controller
        preview.behavior = .transient
        figurePreview = preview
        let position = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        preview.show(relativeTo: NSRect(origin: position, size: .zero), of: self, preferredEdge: .maxY)
    }

    @objc private func copyFigure(_ sender: NSMenuItem) {
        guard let figure = sender.representedObject as? ChatFigureCell, let image = figure.image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc private func saveFigure(_ sender: NSMenuItem) {
        guard let figure = sender.representedObject as? ChatFigureCell, let image = figure.image,
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Figure.png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try png.write(to: url, options: .atomic) }
            catch { NSApp.presentError(error) }
        }
    }

    @objc private func copyFigureSource(_ sender: NSMenuItem) {
        if let figure = sender.representedObject as? ChatFigureCell { copyString(figure.sourceText) }
    }

    private func copyString(_ value: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    public override func copy(_ sender: Any?) { copyString(renderer.markdown(for: selectedRange()) ?? renderer.source) }
    @objc private func replyWithQuote(_ sender: Any?) { quote?(renderer.markdown(for: selectedRange())) }
    @objc private func forkFromHere(_ sender: Any?) { if forkEnabled { fork?() } }
    @objc private func editMessage(_ sender: Any?) { edit?() }
    private func activateLink(_ url: URL) {
        if url.isFileURL {
            if let file = scope.fileURL(url.path(percentEncoded: true)) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        } else if let web = ChatResourceScope.webURL(url.absoluteString) {
            NSWorkspace.shared.open(web)
        }
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { activateLink(url) }
        else if let string = link as? String, let url = ChatResourceScope.webURL(string) { activateLink(url) }
        return true
    }
}
