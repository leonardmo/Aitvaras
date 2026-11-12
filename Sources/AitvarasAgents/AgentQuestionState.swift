import Foundation

/// Request-local draft. Answers are never shared with another card or persisted.
public struct AgentQuestionState: Sendable {
    public let questions: [AgentQuestion]
    private var selected: [String: [String]] = [:]
    private var freeText: [String: String] = [:]

    public init(questions: [AgentQuestion]) { self.questions = questions }
    public func text(for id: String) -> String { freeText[id] ?? "" }
    public func isSelected(_ label: String, for id: String) -> Bool { selected[id]?.contains(label) == true }

    public mutating func select(_ label: String, for id: String) throws {
        guard let question = questions.first(where: { $0.id == id }),
              question.options.contains(where: { $0.label == label }) else { throw AgentFailure.invalidRequest }
        if question.allowsMultiple {
            var values = selected[id] ?? []
            if values.contains(label) { values.removeAll { $0 == label } } else { values.append(label) }
            selected[id] = values
        } else {
            selected[id] = [label]; freeText[id] = ""
        }
    }

    public mutating func setText(_ text: String, for id: String) throws {
        guard let question = questions.first(where: { $0.id == id }), question.allowsFreeText else {
            throw AgentFailure.invalidRequest
        }
        freeText[id] = text
        if !question.allowsMultiple, !text.isEmpty { selected[id] = [] }
    }

    public var answers: [String: [String]]? {
        var result: [String: [String]] = [:]
        for question in questions {
            var values = question.options.filter { isSelected($0.label, for: question.id) }.map(\.label)
            let text = text(for: question.id).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !values.contains(text) { values.append(text) }
            result[question.id] = values
        }
        return (try? Self.validate(result, questions: questions)) == nil ? nil : result
    }

    static func validateQuestions(_ questions: [AgentQuestion]) throws {
        guard !questions.isEmpty, Set(questions.map(\.id)).count == questions.count,
              questions.allSatisfy({ question in
                  !question.id.isEmpty && !question.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && (question.allowsFreeText || !question.options.isEmpty)
                  && Set(question.options.map(\.label)).count == question.options.count
                  && question.options.allSatisfy { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
              }) else { throw AgentFailure.invalidRequest }
    }

    static func validate(_ answers: [String: [String]], questions: [AgentQuestion]) throws {
        try validateQuestions(questions)
        guard Set(answers.keys) == Set(questions.map(\.id)) else { throw AgentFailure.invalidRequest }
        for question in questions {
            let values = answers[question.id] ?? []
            guard !values.isEmpty, question.allowsMultiple || values.count == 1,
                  Set(values).count == values.count,
                  values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw AgentFailure.invalidRequest
            }
            if !question.allowsFreeText, !values.allSatisfy({ value in question.options.contains { $0.label == value } }) {
                throw AgentFailure.invalidRequest
            }
        }
    }
}
