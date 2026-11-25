import SwiftUI

/// Keep a send at the bottom when the reader was already there.
struct ChatTranscriptScroll<Content: View>: View {
    var sendRequest: UUID? = nil
    var overlayBottom: CGFloat = 0
    @ViewBuilder var content: () -> Content

    @AppReduceMotion private var reduceMotion
    @State private var position = ScrollPosition()
    private enum BottomPosition { case bottom, near, away }
    @State private var bottomPosition: BottomPosition = .bottom
    @State private var followsSend = true

    var body: some View {
        ScrollView {
            content().padding(.bottom, overlayBottom)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(followsSend ? .bottom : nil, for: .sizeChanges)
        .scrollPosition($position)
        .transaction { transaction in
            if !followsSend { transaction.scrollContentOffsetAdjustmentBehavior = .disabled }
        }
        .onScrollGeometryChange(for: BottomPosition.self) { geometry in
            let gap = geometry.contentSize.height - geometry.visibleRect.maxY
            if gap <= 2 { return .bottom }
            return gap <= 40 ? .near : .away
        } action: { _, value in
            bottomPosition = value
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting || phase == .decelerating { followsSend = false }
        }
        .onChange(of: sendRequest) {
            followsSend = bottomPosition == .bottom
            if followsSend { position.scrollTo(edge: .bottom) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.transcript")
        .overlay(alignment: .bottomTrailing) {
            if bottomPosition == .away {
                Button("Jump to latest", systemImage: "arrow.down") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        position.scrollTo(y: .greatestFiniteMagnitude)
                    }
                }
                .buttonStyle(.bordered)
                .background(.regularMaterial, in: Capsule())
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .padding(12)
                .padding(.bottom, overlayBottom)
                .accessibilityIdentifier("chat.transcript.latest")
            }
        }
    }
}
