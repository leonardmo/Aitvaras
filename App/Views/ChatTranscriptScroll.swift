import SwiftUI

/// The transcript opens at the latest message. Subsequent scroll commands
/// come from the reader, even when a turn changes the layout.
struct ChatTranscriptScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @AppReduceMotion private var reduceMotion
    @State private var position = ScrollPosition()
    @State private var showsLatest = false

    var body: some View {
        ScrollView {
            content()
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollPosition($position)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY > 40
        } action: { _, value in
            showsLatest = value
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.transcript")
        .overlay(alignment: .bottomTrailing) {
            if showsLatest {
                Button("Jump to latest", systemImage: "arrow.down") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        // SwiftUI clamps this point to the end of the current content.
                        position.scrollTo(y: .greatestFiniteMagnitude)
                    }
                }
                .buttonStyle(.bordered)
                .background(.regularMaterial, in: Capsule())
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .padding(12)
                .accessibilityIdentifier("chat.transcript.latest")
            }
        }
    }
}
