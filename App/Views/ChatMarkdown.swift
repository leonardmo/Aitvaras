import SwiftUI
import AitvarasAgents

/// Shared native Markdown, math and source-aware selection on every chat surface.
struct ChatMarkdown: View {
    let text: String
    var quote: ((String?) -> Void)? = nil
    var fork: (() -> Void)? = nil
    var forkEnabled = false
    var edit: (() -> Void)? = nil
    var streaming = false

    @Environment(\.chatResourceScope) private var scope
    @State private var loadedImages: LoadedImages?

    private struct ImageRequest: Equatable, Sendable {
        let text: String
        let scope: ChatResourceScope
    }

    private struct LoadedImages {
        let request: ImageRequest
        let images: [String: CGImage]
    }

    var body: some View {
        let request = !streaming && !scope.directories.isEmpty && text.contains("![")
            ? ImageRequest(text: text, scope: scope) : nil
        let images = request == loadedImages?.request ? loadedImages?.images ?? [:] : [:]
        NativeChatMarkdown(text: text, scope: scope, images: images, figuresEnabled: !streaming,
                           quote: quote, fork: fork, forkEnabled: forkEnabled, edit: edit)
            .task(id: request) {
                loadedImages = nil
                guard let request else { return }
                let task = Task.detached(priority: .utility) { request.scope.localImages(in: request.text) }
                let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled else { return }
                loadedImages = LoadedImages(request: request, images: result)
            }
    }
}

extension EnvironmentValues {
    @Entry var chatResourceScope = ChatResourceScope()
}

private struct NativeChatMarkdown: NSViewRepresentable {
    let text: String
    let scope: ChatResourceScope
    let images: [String: CGImage]
    let figuresEnabled: Bool
    let quote: ((String?) -> Void)?
    let fork: (() -> Void)?
    let forkEnabled: Bool
    let edit: (() -> Void)?

    func makeNSView(context: Context) -> ChatMessageTextView {
        ChatMessageTextView(frame: .zero, textContainer: nil)
    }

    func updateNSView(_ view: ChatMessageTextView, context: Context) {
        view.update(text, resourceScope: scope, images: images, figuresEnabled: figuresEnabled)
        view.quote = quote; view.fork = fork; view.forkEnabled = forkEnabled; view.edit = edit
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatMessageTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return nsView.measuredSize(width: width)
    }
}
