#if DEBUG
import AppKit

/// Kept independent of launch/bootstrap so a host probe can exercise just the
/// accessibility tree, local press dispatch and composer editing.
@MainActor public final class SelfDriveSurface {
    let window: NSWindow
    public init(window: NSWindow) { self.window = window }

    func nodes() throws -> [any NSAccessibilityProtocol] {
        window.contentView?.layoutSubtreeIfNeeded()
        var pending: [Any] = [window]
        var seen = Set<ObjectIdentifier>()
        var found: [any NSAccessibilityProtocol] = []
        while let object = pending.popLast() {
            guard let node = object as? any NSAccessibilityProtocol else { continue }
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            guard !node.isAccessibilityHidden() else { continue }
            guard seen.count <= 20_000 else { throw SelfDriveFailure("Accessibility tree exceeds node limit") }
            found.append(node)
            pending.append(contentsOf: node.accessibilityChildren() ?? [])
        }
        return found
    }

    func find(_ identifier: String) throws -> (any NSAccessibilityProtocol)? {
        try nodes().first { $0.accessibilityIdentifier() == identifier }
    }

    func press(_ identifier: String) throws -> String {
        guard let element = try find(identifier) else { throw SelfDriveFailure("Identifier unavailable: \(identifier)") }
        guard element.isAccessibilityEnabled() else { throw SelfDriveFailure("Control disabled: \(identifier)") }
        // AppKit menu tracking can depend on real focus and run a modal loop.
        guard !["chat.model", "chat.mode", "chat.effort"].contains(identifier),
              ![NSAccessibility.Role.popUpButton, .menuButton, .menuItem].contains(element.accessibilityRole()) else {
            throw SelfDriveFailure("Native menu tracking requires XCUITest: \(identifier)")
        }
        if element.accessibilityPerformPress() { return "accessibilityPerformPress accepted" }
        let frame = element.accessibilityFrame()
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        guard frame.width > 0, frame.height > 0,
              let content = window.contentView,
              content.bounds.contains(content.convert(point, from: nil)) else {
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
        guard let input = try find("chat.composer.input"), input.isAccessibilityEnabled() else {
            throw SelfDriveFailure("Enabled composer unavailable")
        }
        // AX setters act on the in-process text control without key focus.
        let previous = input.accessibilityValue() as? String ?? ""
        input.setAccessibilityValue(previous + text)
        guard input.accessibilityValue() as? String == previous + text else {
            throw SelfDriveFailure("Composer did not accept the accessibility value without focus")
        }
        return "Composer accessibility value updated; Send/waitFor verifies binding"
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
                let matches = try nodes().contains { node in
                    if let identifier = step.identifier { return node.accessibilityIdentifier() == identifier }
                    let text = step.text!
                    let frame = node.accessibilityFrame()
                    guard frame.width > 0, frame.height > 0, window.frame.intersects(frame) else { return false }
                    return [node.accessibilityLabel(), node.accessibilityTitle(), node.accessibilityValue() as? String]
                        .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(text) }
                }
                if matches != (step.absent ?? false) { return "Condition observed in window accessibility tree" }
                if clock.now >= deadline { break }
                try await Task.sleep(for: .milliseconds(100))
            } while true
            throw SelfDriveFailure("Timed out waiting for \(step.identifier ?? step.text!) (absent: \(step.absent ?? false))")
        case .screenshot:
            guard let content = window.contentView else { throw SelfDriveFailure("Missing content view") }
            content.layoutSubtreeIfNeeded()
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
                "\(index) role=\(node.accessibilityRole()?.rawValue ?? "") id=\(node.accessibilityIdentifier() ?? "") label=\(node.accessibilityLabel() ?? "") value=\(String(describing: node.accessibilityValue())) frame=\(node.accessibilityFrame())"
            }.joined(separator: "\n")
            try Data(tree.utf8).write(to: directory.appendingPathComponent(step.name! + ".txt"), options: .atomic)
            return "Wrote window accessibility tree"
        }
    }
}
#endif
