import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AitvarasAgents

enum ComposerClipboardImage {
    static let types: [UTType] = [.png, .jpeg, .tiff, .heic, .gif, .webP, .bmp]

    @MainActor static func read(from pasteboard: NSPasteboard) -> [Data] {
        (pasteboard.pasteboardItems ?? []).prefix(AgentAttachment.maximumCount).compactMap { item in
            types.lazy.compactMap { item.data(forType: .init($0.identifier)) }.first
        }
    }
}

/// The native field editor can consume ⌘V before SwiftUI's paste command
/// receives image data. Only intercept when the focused composer can attach it.
@MainActor
struct ComposerImagePasteMonitor: NSViewRepresentable {
    let paste: () -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.paste = paste }

    final class MonitorView: NSView {
        var paste: (() -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v", paste?() == true else { return event }
                return nil
            }
        }
    }
}
