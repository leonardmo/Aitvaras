import SwiftUI
import AitvarasAgents

struct AgentApprovalCard: View {
    let request: AgentRequest
    let identifier: String
    var context: String? = nil
    let respond: (AgentResponse) async -> Bool
    @State private var responding = false
    @State private var failed = false

    var body: some View {
        let action = request.presentation
        VStack(alignment: .leading, spacing: 8) {
            if let context { Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Text(action.title).font(.callout.weight(.semibold))
            if !action.detail.isEmpty {
                ScrollView {
                    Text(action.detail).font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
            }
            if let reason = action.reason, !reason.isEmpty {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack {
                Button("Allow") { answer(.allow(updatedInput: nil)) }
                    .buttonStyle(.borderedProminent).tint(Color.accentColor)
                    .foregroundStyle(Color.white)
                    .accessibilityIdentifier("\(identifier).allow")
                Button("Deny") { answer(.deny) }
                    .accessibilityIdentifier("\(identifier).deny")
                if responding { ProgressView().controlSize(.mini) }
            }.disabled(responding || failed)
            if failed { Text("This request is no longer available.").font(.caption).foregroundStyle(.secondary) }
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

/// Suggestions share the coordinator's request; they never dispatch a tool.
struct AgentApprovalSuggestionsView: View {
    @Bindable var chat: ChatModel
    var body: some View {
        ForEach(chat.approvalSuggestions) { suggestion in
            switch suggestion.request.kind {
            case .permission, .permissions:
                AgentApprovalCard(request: suggestion.request, identifier: "chat.suggestion.\(suggestion.id)",
                                  context: chat.approvalContext(suggestion)) { response in
                    await chat.respond(chatID: suggestion.chatID, to: suggestion.request, with: response)
                }
            default: EmptyView()
            }
        }
    }
}
