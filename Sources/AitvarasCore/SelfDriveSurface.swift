#if DEBUG
import AppKit

/// SwiftUI's private accessibility nodes answer the NSAccessibility selectors but do
/// not formally conform to the protocol, so a cast would silently drop them.
@MainActor struct SelfDriveNode {
    let object: NSObject
    private func read(_ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }
    var children: [Any] { read("accessibilityChildren") as? [Any] ?? [] }
    var identifier: String? { read("accessibilityIdentifier") as? String }
    var label: String? { read("accessibilityLabel") as? String }
    var title: String? { read("accessibilityTitle") as? String }
    var value: String? { read("accessibilityValue") as? String }
    var role: String? { (read("accessibilityRole") as? NSAccessibility.Role)?.rawValue ?? read("accessibilityRole") as? String }
    var hidden: Bool { (read("isAccessibilityHidden") as? NSNumber)?.boolValue ?? false }
    var enabled: Bool { (read("isAccessibilityEnabled") as? NSNumber)?.boolValue ?? true }
    var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    func pressAction() -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
    func set(value: String) {
        let selector = NSSelectorFromString("setAccessibilityValue:")
        if object.responds(to: selector) { object.perform(selector, with: value) }
    }
}

/// Kept independent of launch/bootstrap so a host probe can exercise just the
/// accessibility tree, local press dispatch and composer editing.
@MainActor public final class SelfDriveSurface {
    let window: NSWindow
    public init(window: NSWindow) { self.window = window }

    func nodes(root: NSObject? = nil) throws -> [SelfDriveNode] {
        window.contentView?.layoutSubtreeIfNeeded()
        window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
        // A SwiftUI sheet is a separate attached window; include its tree so a
        // scenario can drive it. Popped last, so the sheet's nodes win ties.
        var pending: [Any] = [root ?? window]
        if root == nil {
            pending.append(contentsOf: window.childWindows ?? [])
            if let sheet = window.attachedSheet { pending.append(sheet) }
        }
        var seen = Set<ObjectIdentifier>()
        var found: [SelfDriveNode] = []
        while let next = pending.popLast() {
            guard let object = next as? NSObject else { continue }
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let node = SelfDriveNode(object: object)
            guard !node.hidden else { continue }
            guard seen.count <= 20_000 else { throw SelfDriveFailure("Accessibility tree exceeds node limit") }
            found.append(node)
            pending.append(contentsOf: node.children)
        }
        return found
    }

    func find(_ identifier: String) throws -> SelfDriveNode? {
        try nodes().first { $0.identifier == identifier }
    }

    func press(_ identifier: String) throws -> String {
        guard let element = try find(identifier) else { throw SelfDriveFailure("Identifier unavailable: \(identifier)") }
        return try press(element, target: identifier)
    }

    private func press(_ element: SelfDriveNode, target identifier: String) throws -> String {
        guard element.enabled else { throw SelfDriveFailure("Control disabled: \(identifier)") }
        // AppKit menu tracking can depend on real focus and run a modal loop.
        guard !["AXPopUpButton", "AXMenuButton", "AXMenuItem"].contains(element.role ?? "") else {
            throw SelfDriveFailure("Native menu tracking requires XCUITest: \(identifier)")
        }
        if element.pressAction() { return "accessibilityPerformPress accepted" }
        let frame = element.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let windows = [window.attachedSheet].compactMap { $0 } + (window.childWindows ?? []).reversed() + [window]
        let target = windows.first { $0.frame.contains(center) }
        guard frame.width > 0, frame.height > 0, let target else {
            throw SelfDriveFailure("No in-window press target: \(identifier)")
        }
        let point = target.convertPoint(fromScreen: center)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw SelfDriveFailure("Could not create local mouse event")
            }
            target.sendEvent(event)
        }
        return "Dispatched local window mouse events; verify effect with waitFor"
    }

    private func drag(_ identifier: String, verticalBy distance: Double) throws -> String {
        guard let element = try find(identifier), element.enabled, !element.frame.isEmpty else {
            throw SelfDriveFailure("Drag target unavailable: \(identifier)")
        }
        let start = window.convertPoint(fromScreen: NSPoint(x: element.frame.midX, y: element.frame.midY))
        let events: [(NSEvent.EventType, Double)] = [
            (.leftMouseDown, 0), (.leftMouseDragged, 0.24), (.leftMouseDragged, 0.60),
            (.leftMouseDragged, 1), (.leftMouseUp, 1)
        ]
        for (type, fraction) in events {
            let point = NSPoint(x: start.x, y: start.y + distance * fraction)
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                throw SelfDriveFailure("Could not create local drag event")
            }
            window.sendEvent(event)
        }
        return "Dispatched local vertical drag"
    }

    private func editableField(for identifier: String) throws -> NSView {
        guard let input = try find(identifier), input.enabled else {
            throw SelfDriveFailure("Enabled text input unavailable: \(identifier)")
        }
        // The accessibility setter changes the field but skips SwiftUI's binding, so the
        // text goes through the field's own editor. A non-key window can still hold a
        // first responder, which leaves the person's keyboard focus alone.
        let frame = input.frame
        func editable(in view: NSView) -> NSView? {
            for child in view.subviews {
                if let found = editable(in: child) { return found }
            }
            guard view is NSTextView || (view as? NSTextField)?.isEditable == true else { return nil }
            let onScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
            return onScreen.intersects(frame) ? view : nil
        }
        guard let content = window.contentView, let field = editable(in: content) else {
            throw SelfDriveFailure("No editable view for \(identifier)")
        }
        return field
    }

    private func fieldEditor(for identifier: String, takeFocus: Bool) throws -> NSTextView {
        let field = try editableField(for: identifier)
        if takeFocus, !window.makeFirstResponder(field) {
            throw SelfDriveFailure("Text input refused first responder: \(identifier)")
        }
        let editor = (field as? NSTextView) ?? (field as? NSTextField)?.currentEditor() as? NSTextView
        guard let editor else { throw SelfDriveFailure("Text input has no field editor: \(identifier)") }
        guard window.firstResponder === editor else { throw SelfDriveFailure("Text input lost focus: \(identifier)") }
        return editor
    }

    private func selectText(_ text: String, in identifier: String) throws -> String {
        let editor = try fieldEditor(for: identifier, takeFocus: true)
        let range = (editor.string as NSString).range(of: text)
        guard range.location != NSNotFound else { throw SelfDriveFailure("Selection text unavailable in \(identifier)") }
        editor.setSelectedRange(range)
        return "Selected text through the field editor"
    }

    func type(_ text: String, into identifier: String, atSelection: Bool = false) throws -> String {
        let editor = try fieldEditor(for: identifier, takeFocus: !atSelection)
        let range = atSelection ? editor.selectedRange() : NSRange(location: editor.string.utf16.count, length: 0)
        editor.insertText(text, replacementRange: range)
        guard editor.string.contains(text) else {
            throw SelfDriveFailure("Text input did not show the typed text: \(identifier)")
        }
        return "Inserted through the field editor"
    }

    public func perform(_ step: SelfDriveStep, directory: URL) async throws -> String {
        switch step.action {
        case .drag:
            let reason = try drag(step.identifier!, verticalBy: step.verticalBy!)
            await Task.yield()
            return reason
        case .press:
            if let text = step.text {
                let root = try step.within.flatMap(find)
                if let within = step.within, root == nil {
                    throw SelfDriveFailure("Subtree unavailable: \(within)")
                }
                let matches = try nodes(root: root?.object).filter { node in
                    node.enabled && node.role == NSAccessibility.Role.button.rawValue &&
                        [node.label, node.title].compactMap { $0 }.contains {
                            SelfDriveText.matches($0, text: text, caseSensitive: step.caseSensitive ?? false)
                        }
                }
                guard matches.count == 1, let match = matches.first else {
                    throw SelfDriveFailure("Expected one enabled button matching \(text), found \(matches.count)")
                }
                let reason = try press(match, target: match.identifier ?? text)
                await Task.yield()
                return reason
            }
            let targets = step.anyOf ?? [step.identifier!]
            guard let target = try targets.first(where: { try find($0)?.enabled == true }) else {
                throw SelfDriveFailure("No enabled press target: \(targets.joined(separator: " or "))")
            }
            let reason = try press(target)
            await Task.yield()
            return reason
        case .type:
            let reason = try type(step.text!, into: step.identifier ?? "chat.composer.input", atSelection: step.atSelection == true)
            await Task.yield()
            return reason
        case .selectText:
            return try selectText(step.text!, in: step.identifier ?? "chat.composer.input")
        case .waitFor:
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(step.timeout ?? 10))
            repeat {
                let candidates: [SelfDriveNode]
                let subtreeAvailable: Bool
                if let within = step.within {
                    let root = try find(within)
                    subtreeAvailable = root != nil
                    candidates = try root.map { try nodes(root: $0.object) } ?? []
                } else { candidates = try nodes(); subtreeAvailable = true }
                let matches = candidates.contains { node in
                    if let enabled = step.enabled, node.enabled != enabled { return false }
                    if step.identifier != nil || step.anyOf != nil { return step.matchesIdentifier(node.identifier) }
                    let text = step.text!
                    let frame = node.frame
                    guard frame.width > 0, frame.height > 0,
                          window.frame.intersects(frame) || window.attachedSheet?.frame.intersects(frame) == true
                    else { return false }
                    return [node.label, node.title, node.value]
                        .compactMap { $0 }.contains { SelfDriveText.matches($0, text: text, caseSensitive: step.caseSensitive ?? false) }
                }
                if subtreeAvailable && matches != (step.absent ?? false) { return "Condition observed in window accessibility tree" }
                if clock.now >= deadline { break }
                try await Task.sleep(for: .milliseconds(100))
            } while true
            let target = step.identifier ?? step.text ?? step.anyOf!.joined(separator: " or ")
            throw SelfDriveFailure("Timed out waiting for \(target) (absent: \(step.absent ?? false))")
        case .screenshot:
            guard let content = window.contentView else { throw SelfDriveFailure("Missing content view") }
            try Self.cache(content, to: directory.appendingPathComponent(step.name! + ".png"))
            // An attached sheet is its own window; save it next to the main view.
            if let sheet = window.attachedSheet?.contentView {
                try Self.cache(sheet, to: directory.appendingPathComponent(step.name! + "-sheet.png"))
                return "Cached window and attached sheet content views"
            }
            return "Cached window content view"
        case .dumpTree:
            let tree = try nodes().enumerated().map { index, node in
                "\(index) role=\(node.role ?? "") id=\(node.identifier ?? "") label=\(node.label ?? "") value=\(node.value ?? "nil") frame=\(node.frame)"
            }.joined(separator: "\n")
            try Data(tree.utf8).write(to: directory.appendingPathComponent(step.name! + ".txt"), options: .atomic)
            return "Wrote window accessibility tree"
        }
    }

    private static func cache(_ content: NSView, to url: URL) throws {
        content.layoutSubtreeIfNeeded()
        // cacheDisplay skips the window's own background, which SwiftUI text assumes.
        content.wantsLayer = true
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw SelfDriveFailure("Could not allocate content bitmap")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SelfDriveFailure("Could not encode PNG")
        }
        try png.write(to: url, options: .atomic)
    }
}
#endif
