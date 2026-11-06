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
        var pending: [Any] = [root ?? window]
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
        guard element.enabled else { throw SelfDriveFailure("Control disabled: \(identifier)") }
        // AppKit menu tracking can depend on real focus and run a modal loop.
        guard !["chat.model", "chat.mode", "chat.effort", "chat.project"].contains(identifier),
              !["AXPopUpButton", "AXMenuButton", "AXMenuItem"].contains(element.role ?? "") else {
            throw SelfDriveFailure("Native menu tracking requires XCUITest: \(identifier)")
        }
        if element.pressAction() { return "accessibilityPerformPress accepted" }
        let frame = element.frame
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        guard frame.width > 0, frame.height > 0,
              window.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) else {
            throw SelfDriveFailure("No in-window press target: \(identifier)")
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw SelfDriveFailure("Could not create local mouse event")
            }
            window.sendEvent(event)
        }
        return "Dispatched local window mouse events; verify effect with waitFor"
    }

    func type(_ text: String) throws -> String {
        guard let input = try find("chat.composer.input"), input.enabled else {
            throw SelfDriveFailure("Enabled composer unavailable")
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
            throw SelfDriveFailure("No editable view behind the composer")
        }
        guard window.makeFirstResponder(field) else { throw SelfDriveFailure("Composer refused first responder") }
        let editor = (field as? NSTextView) ?? (field as? NSTextField)?.currentEditor() as? NSTextView
        guard let editor else { throw SelfDriveFailure("Composer has no field editor") }
        editor.insertText(text, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        guard (input.value ?? "").contains(text) else {
            throw SelfDriveFailure("Composer did not show the typed text")
        }
        return "Inserted through the field editor"
    }

    public func perform(_ step: SelfDriveStep, directory: URL) async throws -> String {
        switch step.action {
        case .press:
            let reason = try press(step.identifier!)
            await Task.yield()
            return reason
        case .type:
            let reason = try type(step.text!)
            await Task.yield()
            return reason
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
                    if step.identifier != nil || step.anyOf != nil { return step.matchesIdentifier(node.identifier) }
                    let text = step.text!
                    let frame = node.frame
                    guard frame.width > 0, frame.height > 0, window.frame.intersects(frame) else { return false }
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
            try png.write(to: directory.appendingPathComponent(step.name! + ".png"), options: .atomic)
            return "Cached window content view"
        case .dumpTree:
            let tree = try nodes().enumerated().map { index, node in
                "\(index) role=\(node.role ?? "") id=\(node.identifier ?? "") label=\(node.label ?? "") value=\(node.value ?? "nil") frame=\(node.frame)"
            }.joined(separator: "\n")
            try Data(tree.utf8).write(to: directory.appendingPathComponent(step.name! + ".txt"), options: .atomic)
            return "Wrote window accessibility tree"
        }
    }
}
#endif
