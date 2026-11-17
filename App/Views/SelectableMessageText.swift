import AppKit
import SwiftUI

/// Native read-only selection spans paragraphs and code. Other surfaces retain
/// ChatMarkdown; the selected substring is passed transiently to the composer.
struct SelectableMessageText: NSViewRepresentable {
    let text: String
    let quote: (String?) -> Void
    var fork: (() -> Void)? = nil
    var forkEnabled = false

    func makeNSView(context: Context) -> MessageTextView {
        let view = MessageTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.drawsBackground = false; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0; view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor
        return view
    }
    func updateNSView(_ view: MessageTextView, context: Context) {
        if view.string != text { view.string = text }
        view.quote = quote; view.fork = fork; view.forkEnabled = forkEnabled
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        let width = max(1, proposal.width ?? 600)
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(20, ceil(layout.usedRect(for: container).height)))
    }

    final class MessageTextView: NSTextView {
        var quote: ((String?) -> Void)?
        var fork: (() -> Void)?
        var forkEnabled = false
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            copy.target = self; copy.isEnabled = selectedRange().length > 0; menu.addItem(copy)
            let reply = NSMenuItem(title: "Reply with quote", action: #selector(replyWithQuote(_:)), keyEquivalent: "")
            reply.target = self; menu.addItem(reply)
            if fork != nil {
                let item = NSMenuItem(title: "Fork from here", action: #selector(forkFromHere(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = forkEnabled; menu.addItem(item)
            }
            return menu
        }
        @objc private func replyWithQuote(_ sender: Any?) {
            let range = selectedRange(), text = string as NSString
            quote?(range.length > 0 && NSMaxRange(range) <= text.length ? text.substring(with: range) : nil)
        }
        @objc private func forkFromHere(_ sender: Any?) { if forkEnabled { fork?() } }
    }
}
