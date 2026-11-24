import AppKit
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
