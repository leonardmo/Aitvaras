import SwiftUI
import AitvarasAgents

struct AgentQuestionCard: View {
    let request: AgentRequest
    let index: Int
    let respond: (AgentResponse) async -> Bool
    @State private var draft: AgentQuestionState
    @State private var responding = false
    @State private var failed = false

    init(request: AgentRequest, index: Int, respond: @escaping (AgentResponse) async -> Bool) {
        self.request = request; self.index = index; self.respond = respond
        let questions: [AgentQuestion]
        if case .questions(let values) = request.kind { questions = values } else { questions = [] }
        _draft = State(initialValue: AgentQuestionState(questions: questions))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(draft.questions.enumerated()), id: \.element.id) { questionIndex, question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.prompt).font(.callout.weight(.medium)).textSelection(.enabled)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        Button {
                            try? draft.select(option.label, for: question.id)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: draft.isSelected(option.label, for: question.id)
                                      ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                    if !option.description.isEmpty {
                                        Text(option.description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(draft.isSelected(option.label, for: question.id) ? "Selected" : "Not selected")
                        .accessibilityIdentifier("chat.question.\(index).\(questionIndex).option.\(optionIndex)")
                    }
                    if question.allowsFreeText {
                        if question.isSecret {
                            SecureField("Answer", text: answer(question.id))
                                .accessibilityIdentifier("chat.question.\(index).\(question.id)")
                        } else {
                            TextField(question.options.isEmpty ? "Answer" : "Your answer", text: answer(question.id), axis: .vertical)
                                .lineLimit(1...4)
                                .accessibilityIdentifier("chat.question.\(index).\(question.id)")
                        }
                    }
                }
            }
            HStack {
                Button("Submit") {
                    if let answers = draft.answers { submit(.answers(answers)) }
                }
                .disabled(draft.answers == nil)
                .accessibilityIdentifier("chat.request.\(index).submit")
                Button("Cancel") { submit(.deny) }
                    .accessibilityIdentifier("chat.request.\(index).deny")
                if responding { ProgressView().controlSize(.mini) }
            }
            if failed { Text("This question is no longer available.").font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(responding || failed)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.questions.\(request.identity)")
    }

    private func answer(_ id: String) -> Binding<String> {
        Binding(get: { draft.text(for: id) }, set: { try? draft.setText($0, for: id) })
    }
    private func submit(_ response: AgentResponse) {
        guard !responding, !failed else { return }
        responding = true
        Task { failed = !(await respond(response)); responding = false }
    }
}
