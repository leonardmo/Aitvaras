import SwiftUI
import AitvarasAgents

struct AgentPlanCard: View {
    let request: AgentRequest
    let identifier: String
    let respond: (AgentResponse) async -> Bool
    @State private var responding = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .plan(let text) = request.kind {
                ChatMarkdown(text: AgentTranscriptContent.bounded(text))
                    .accessibilityIdentifier("chat.plan.\(request.identity).content")
            }
            HStack {
                Button("Approve") { answer(.allow(updatedInput: nil)) }
                    .accessibilityIdentifier("\(identifier).allow")
                Button("Keep planning") { answer(.deny) }
                    .accessibilityIdentifier("\(identifier).deny")
                if responding { ProgressView().controlSize(.mini) }
            }.disabled(responding || failed)
            if failed {
                Text("This plan is no longer available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.approval.\(request.identity)")
    }

    private func answer(_ response: AgentResponse) {
        guard !responding, !failed else { return }
        responding = true
        Task { failed = !(await respond(response)); responding = false }
    }
}
