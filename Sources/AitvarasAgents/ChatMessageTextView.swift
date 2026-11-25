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
    private var controls: [Int: (CodeCopyButton, NSScroller)] = [:]
    var codePasteboard = NSPasteboard.general
    private static let codeInset: CGFloat = 12
    private static let codeHeaderHeight: CGFloat = 32
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
            for block in renderer.codeBlocks where !block.wraps && block.range.location >= replacement.location {
                let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                codeWidths[block.range.location] = block.code.components(separatedBy: "\n").map {
                    ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 2 * Self.codeInset + 1
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
                let panel = codePanel(for: block, layout: layout, container: container)
                guard panel.intersects(dirtyRect) else { continue }
                let outline = NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                NSColor.labelColor.withAlphaComponent(0.045).setFill()
                outline.fill()
                NSColor.labelColor.withAlphaComponent(0.16).setStroke()
                outline.stroke()
                let y = panel.minY + Self.codeHeaderHeight
                NSBezierPath.strokeLine(from: NSPoint(x: panel.minX + 1, y: y),
                                        to: NSPoint(x: panel.maxX - 1, y: y))
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
        let tables = applyParagraphStyles(width: width, to: scratchStorage, container: scratchContainer)
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

    private func codePanel(for block: ChatCodeBlock, layout: NSLayoutManager, container: NSTextContainer) -> NSRect {
        let glyphs = layout.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .zero }
        let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layout.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return NSRect(x: 0, y: first.minY, width: viewportWidth, height: max(0, last.maxY - first.minY - 6))
    }

    private func codeWidth(_ block: ChatCodeBlock) -> CGFloat {
        codeWidth(block, viewport: viewportWidth)
    }

    private func codeWidth(_ block: ChatCodeBlock, viewport: CGFloat) -> CGFloat {
        max(viewport, codeWidths[block.range.location] ?? 0)
    }

    private func constrainParagraphs(in requested: NSRange? = nil) {
        guard viewportWidth > 0, let storage = textStorage, let container = textContainer else { return }
        _ = applyParagraphStyles(width: viewportWidth, to: storage, container: container, in: requested)
        positionCodeControls()
    }

    /// Fits `storage` to `width` and returns each table's previous width.
    @discardableResult
    private func applyParagraphStyles(width viewportWidth: CGFloat, to storage: NSTextStorage,
                                      container: NSTextContainer,
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
                let inset = Self.codeInset
                let content = NSIntersectionRange(block.contentRange, range).length > 0
                let offset = content && !block.wraps ? offsets[block.range.location] ?? 0 : 0
                let width = content && !block.wraps ? codeWidth(block) : viewportWidth
                style.headIndent = inset - offset
                style.firstLineHeadIndent = inset - offset
                style.tailIndent = max(inset + 1, width - inset) - offset
                style.lineBreakMode = block.wraps ? .byWordWrapping : .byCharWrapping
                if range.location == block.range.location {
                    style.minimumLineHeight = Self.codeHeaderHeight
                    style.tailIndent = max(inset + 1, viewportWidth - 78)
                    style.lineBreakMode = .byTruncatingTail
                } else if !content {
                    style.minimumLineHeight = codeWidth(block) > viewportWidth ? 25 : 15
                    style.maximumLineHeight = style.minimumLineHeight
                } else if range.location == block.contentRange.location {
                    style.paragraphSpacingBefore = 5
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
            let pair: (CodeCopyButton, NSScroller)
            if let existing = controls[id] { pair = existing }
            else {
                let copy = CodeCopyButton()
                copy.target = self
                copy.action = #selector(copyCode(_:))
                copy.tag = id
                copy.setAccessibilityIdentifier("chat.code.copy.\(id)")
                copy.setAccessibilityParent(self)
                // NSScroller takes its orientation from the initial frame.
                let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 15))
                scroller.scrollerStyle = .legacy; scroller.controlSize = .small
                scroller.target = self; scroller.action = #selector(scrollCode(_:)); scroller.tag = id
                scroller.setAccessibilityLabel("Scroll code horizontally")
                scroller.setAccessibilityParent(self)
                addSubview(copy); addSubview(scroller); pair = (copy, scroller); controls[id] = pair
            }
            let rect = codePanel(for: block, layout: layout, container: container)
            let buttonWidth = min(66, max(0, viewportWidth - 12))
            pair.0.frame = NSRect(x: max(0, viewportWidth - buttonWidth - 6),
                                  y: rect.minY + 5, width: buttonWidth, height: 22)
            let extent = max(0, codeWidth(block) - viewportWidth)
            pair.1.isHidden = extent < 1
            pair.1.isEnabled = extent >= 1
            let thickness = NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
            pair.1.frame = NSRect(x: Self.codeInset, y: max(rect.minY, rect.maxY - thickness - 2),
                                  width: max(0, viewportWidth - 2 * Self.codeInset), height: thickness)
            pair.1.knobProportion = min(1, viewportWidth / max(1, codeWidth(block)))
            pair.1.doubleValue = extent > 0 ? Double((offsets[id] ?? 0) / extent) : 0
        }
    }

    public override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        // NSTextView advertises its links but omits the controls we embed.
        for id in controls.keys.sorted() {
            guard let (button, scroller) = controls[id] else { continue }
            for control: NSControl in [button, scroller] where !control.isHidden {
                if !children.contains(where: { $0 as AnyObject === control }) { children.append(control) }
            }
        }
        return children
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // Give the native button priority over the text selection surface.
        if let superview, !isHiddenOrHasHiddenAncestor {
            let location = convert(point, from: superview)
            if bounds.contains(location),
               let button = controls.values.lazy.map(\.0).first(where: { !$0.isHidden && $0.frame.contains(location) }) {
                return button
            }
        }
        return super.hitTest(point)
    }

    @objc private func copyCode(_ sender: CodeCopyButton) {
        guard let block = renderer.codeBlocks.first(where: { $0.range.location == sender.tag }) else { return }
        codePasteboard.clearContents()
        if codePasteboard.setString(block.code, forType: .string) { sender.showConfirmation() }
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
                !$0.wraps && codeWidth($0) > viewportWidth
                    && codePanel(for: $0, layout: layout, container: container).contains(point)
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
        } else if let figure = figure(at: event) {
            if toolTip != figure.caption { toolTip = figure.caption }
            NSCursor.pointingHand.set()
        } else {
            if toolTip != nil { toolTip = nil }
            super.mouseMoved(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, !event.modifierFlags.contains(.control), let figure = figure(at: event) {
            showFigure(figure, at: convert(event.locationInWindow, from: nil))
        } else {
            super.mouseDown(with: event)
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
        guard let figure = sender.representedObject as? ChatFigureCell else { return }
        showFigure(figure, at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    private func showFigure(_ figure: ChatFigureCell, at position: NSPoint) {
        guard let image = figure.image else { return }
        figurePreview?.close()
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

@MainActor private final class CodeCopyButton: NSButton {
    private var confirmation: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        title = "Copy"
        bezelStyle = .roundRect
        controlSize = .small
        toolTip = "Copy code"
        setAccessibilityLabel("Copy code")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityChildren() -> [Any]? { nil }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    func showConfirmation() {
        confirmation?.cancel()
        title = "Copied"
        setAccessibilityLabel("Code copied")
        confirmation = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) }
            catch { return }
            self?.title = "Copy"
            self?.setAccessibilityLabel("Copy code")
        }
    }
}
