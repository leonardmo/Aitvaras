import Foundation

/// Only the question-card subset of opencode's forms. Unsupported validation,
/// conditional visibility and external controls must be cancelled, never hidden.
struct OpencodeForm: Sendable {
    let questions: [AgentQuestion]
    private let values: [String: [String: String]]

    init(_ form: JSONValue) throws {
        guard let fields = form["fields"]?.arrayValue, fields.count <= 64 else { throw AgentFailure.unsupported }
        var questions: [AgentQuestion] = [], values: [String: [String: String]] = [:]
        for field in fields {
            let supported: Set<String> = ["key", "type", "title", "description", "required", "hidden", "when",
                "default", "placeholder", "options", "custom", "minItems", "minLength"]
            guard let object = field.objectValue, Set(object.keys).isSubset(of: supported),
                  let key = field["key"]?.stringValue,
                  let type = field["type"]?.stringValue, ["string", "multiselect"].contains(type),
                  field["hidden"]?.boolValue != true,
                  field["when"] == nil || field["when"]?.arrayValue == [],
                  field["required"]?.boolValue != false,
                  ["minItems", "minLength"].allSatisfy({ field[$0] == nil || field[$0]?.int.map { (0...1).contains($0) } == true })
            else { throw AgentFailure.unsupported }
            let options: [JSONValue]
            if let raw = field["options"] {
                guard let array = raw.arrayValue, array.count <= 128 else { throw AgentFailure.unsupported }
                options = array
            } else {
                guard type == "string" else { throw AgentFailure.unsupported }
                options = []
            }
            var labels: [String: String] = [:], choices: [AgentQuestion.Option] = []
            for option in options {
                guard let label = option["label"]?.stringValue, let value = option["value"]?.stringValue,
                      labels[label] == nil, !labels.values.contains(value) else { throw AgentFailure.unsupported }
                labels[label] = value
                choices.append(.init(label: label, description: option["description"]?.stringValue ?? ""))
            }
            let prompt = [field["title"]?.stringValue, field["description"]?.stringValue]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            questions.append(.init(id: key, prompt: prompt.isEmpty ? (form["title"]?.stringValue ?? "") : prompt,
                options: choices, allowsMultiple: type == "multiselect",
                allowsFreeText: options.isEmpty || field["custom"]?.boolValue == true))
            values[key] = labels
        }
        try AgentQuestionState.validateQuestions(questions)
        self.questions = questions; self.values = values
    }

    func reply(_ answers: [String: [String]]) throws -> JSONValue {
        try AgentQuestionState.validate(answers, questions: questions)
        var answer: [String: JSONValue] = [:]
        for question in questions {
            let mapped = answers[question.id]!.map { values[question.id]?[$0] ?? $0 }
            answer[question.id] = question.allowsMultiple ? .array(mapped.map(JSONValue.string)) : .string(mapped[0])
        }
        return .object(["answer": .object(answer)])
    }
}

func opencodeRequestID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count < 256 && id.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
    }
}

func opencodeEventSession(_ value: JSONValue) -> String? {
    value["data"]?["sessionID"]?.stringValue ?? value["data"]?["form"]?["sessionID"]?.stringValue
}
