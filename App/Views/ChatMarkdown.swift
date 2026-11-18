import SwiftUI
import AitvarasAgents

/// Shared native Markdown, math and source-aware selection on every chat surface.
struct ChatMarkdown: NSViewRepresentable {
    let text: String
    var quote: ((String?) -> Void)? = nil
    var fork: (() -> Void)? = nil
    var forkEnabled = false
    var edit: (() -> Void)? = nil

    func makeNSView(context: Context) -> ChatMessageTextView {
        ChatMessageTextView(frame: .zero, textContainer: nil)
    }
    func updateNSView(_ view: ChatMessageTextView, context: Context) {
        view.update(text)
        view.quote = quote; view.fork = fork; view.forkEnabled = forkEnabled; view.edit = edit
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatMessageTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return nsView.measuredSize(width: width)
    }
}
