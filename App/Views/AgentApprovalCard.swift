import SwiftUI
import AitvarasAgent
import AitvarasAgents

struct AgentApprovalCard: View {
    let request: AgentRequest
    let identifier: String
    var context: String? = nil
    var grantAvailable = true
    var alwaysAllow: (() async -> Bool)? = nil
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
            if grantAvailable, request.canAlwaysAllowInProject, let alwaysAllow {
                Button("Always allow in this project") {
                    guard !responding, !failed else { return }
                    responding = true
                    Task { failed = !(await alwaysAllow()); responding = false }
                }
                .accessibilityIdentifier("\(identifier).alwaysAllow")
                .disabled(responding || failed)
            }
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
                                  context: chat.approvalContext(suggestion), grantAvailable: chat.canAlwaysAllow(chatID: suggestion.chatID, request: suggestion.request), alwaysAllow: {
                    await chat.alwaysAllow(chatID: suggestion.chatID, request: suggestion.request)
                }) { response in
                    await chat.respond(chatID: suggestion.chatID, to: suggestion.request, with: response)
                }
            default: EmptyView()
            }
        }
    }
}

/// Both surfaces render the same one-shot request IDs from the app's broker.
struct GatewayAttentionCards: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.gatewayOutsideApprovals) { request in
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow \(request.toolName)?").font(.callout.weight(.semibold))
                Text(request.invocation.context.client.rawValue.capitalized + " outside Chat")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Arguments") {
                    ScrollView {
                        Text(verbatim: request.arguments.jsonString).font(.caption.monospaced())
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }
                HStack {
                    Button("Allow") { Task { await model.decideGatewayApproval(request, allow: true) } }
                        .buttonStyle(.borderedProminent)
                    Button("Deny") { Task { await model.decideGatewayApproval(request, allow: false) } }
                }
            }
            .padding(12).frame(width: 308, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("gateway.outside.approval.\(request.id)")
        }
        ForEach(model.gatewaySignInRequests) { request in
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to \(request.server) in Aitvaras").font(.callout.weight(.semibold))
                if model.gatewaySigningIn == request.id {
                    Button("Cancel") { model.cancelGatewaySignIn() }
                } else {
                    Button("Sign in") { model.startGatewaySignIn(request.id) }
                        .disabled(model.gatewaySigningIn != nil)
                }
                if let error = model.gatewaySignInError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(width: 308, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("gateway.outside.signin.\(request.id)")
        }
    }
}

struct GatewaySuggestionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.gatewayAttentionCount > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) { GatewayAttentionCards() }
                    .padding(8)
            }
        }
    }
}
