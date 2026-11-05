import Foundation
import Testing
@testable import AitvarasAgents

@Suite struct AgentQuestionTests {
    @Test func recordedOptionsAndAnswerRoundTrip() async throws {
        let fixture = try BackendExecutableFixture(provider: "claude", name: "question")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "haiku"))
        try await run.send(.init(text: try fixture.prompt(provider: "claude", name: "question")), willDeliver: {})
        let events = try await collectTurn(run)
        let questions = try #require(events.compactMap { event -> [AgentQuestion]? in
            if case .request(let r) = event.kind, case .questions(let questions) = r.kind { return questions }
            return nil
        }.first)
        #expect(questions.first?.options.map(\.label) == ["Red", "Blue"])
        #expect(questions.first?.allowsFreeText == true)
        #expect(questions.first?.allowsMultiple == false)
        try await planWait { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete(); try await run.shutdown()
    }

    @Test func draftsRequireEveryAnswerAndRespectChoices() throws {
        let questions = [
            AgentQuestion(id: "color", prompt: "Color?", options: [.init(label: "Red", description: "Warm"), .init(label: "Blue", description: "Cool")], allowsFreeText: false),
            AgentQuestion(id: "features", prompt: "Features?", options: [.init(label: "Fast", description: ""), .init(label: "Small", description: "")], allowsMultiple: true),
            AgentQuestion(id: "detail", prompt: "Details?")
        ]
        var draft = AgentQuestionState(questions: questions)
        #expect(draft.answers == nil)
        #expect(throws: AgentFailure.invalidRequest) { try draft.select("Red", for: "unknown") }
        #expect(throws: AgentFailure.invalidRequest) { try draft.select("Green", for: "color") }
        #expect(throws: AgentFailure.invalidRequest) { try draft.setText("Green", for: "color") }
        try draft.select("Red", for: "color")
        try draft.select("Blue", for: "color")
        #expect(!draft.isSelected("Red", for: "color"))
        try draft.select("Fast", for: "features")
        try draft.select("Small", for: "features")
        try draft.setText("Quiet", for: "features")
        try draft.setText("   ", for: "detail")
        #expect(draft.answers == nil)
        try draft.setText(" Example ", for: "detail")
        #expect(draft.answers == ["color": ["Blue"], "features": ["Fast", "Small", "Quiet"], "detail": ["Example"]])
        try draft.select("Fast", for: "features")
        #expect(draft.answers?["features"] == ["Small", "Quiet"])
        let otherCard = AgentQuestionState(questions: questions)
        #expect(otherCard.answers == nil)
    }

    @Test func freeTextAndSingleSelectionReplaceEachOther() throws {
        var state = AgentQuestionState(questions: [.init(id: "q", prompt: "Choose", options: [.init(label: "First", description: "")])])
        try state.select("First", for: "q")
        try state.setText("Custom", for: "q")
        #expect(state.answers == ["q": ["Custom"]])
        try state.select("First", for: "q")
        #expect(state.text(for: "q").isEmpty)
        #expect(state.answers == ["q": ["First"]])
    }

    @Test func schemaFlagsAndMalformedQuestions() throws {
        let value = try #require(JSONValue.parse(#"[{"id":"q","question":"Choose","header":"Choice","isOther":false,"isSecret":true,"options":[{"label":"First","description":"Example"}]}]"#))
        let question = try #require(agentQuestions(value, claude: false).first)
        #expect(!question.allowsFreeText && !question.allowsMultiple && question.isSecret)
        let textOnly = try agentQuestions(.array([.object(["id": .string("text"), "question": .string("Details?"), "options": .null])]), claude: false)
        #expect(textOnly.first?.allowsFreeText == true)
        let other = try agentQuestions(.array([.object(["id": .string("q"), "question": .string("Choose"), "isOther": .bool(true), "options": value.arrayValue![0]["options"]!])]), claude: false)
        #expect(other.first?.allowsFreeText == true)
        for malformed in [JSONValue.null, .array([]), .array([value.arrayValue![0], value.arrayValue![0]]),
                          .array([.object(["id": .string("q"), "question": .string("Choose"), "options": .string("bad")])])] {
            #expect(throws: AgentFailure.invalidRequest) { try agentQuestions(malformed, claude: false) }
        }
        for answers in [[String: [String]](), ["unknown": ["First"]], ["q": []], ["q": [" "]],
                        ["q": ["Other"]], ["q": ["First", "First"]]] {
            #expect(throws: AgentFailure.invalidRequest) { try AgentQuestionState.validate(answers, questions: [question]) }
        }
    }

    @Test(arguments: [AgentProvider.claude, .codex], [false, true])
    func multipleQuestionsRoundTripOrCancel(provider: AgentProvider, cancel: Bool) async throws {
        let fixture = try BackendExecutableFixture(script: questionScript(provider: provider, cancel: cancel))
        defer { fixture.remove() }
        let backend: any AgentBackend = provider == .claude
            ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
            : CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let raw = try await backend.start(.init(directory: fixture.directory, model: "test"))
        let run = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: UUID()), audit: { _ in })
        try await run.send(.init(text: "Ask questions"), willDeliver: {})
        var answered: AgentRequest?
        for try await event in run.events {
            if case .request(let request) = event.kind, case .questions(let questions) = request.kind {
                #expect(questions.count == 2)
                #expect(request.isBlocking == (provider == .claude))
                answered = request
                await #expect(throws: AgentFailure.invalidRequest) {
                    try await run.respond(to: request, with: .answers(["unknown": ["Red"]]))
                }
                await #expect(throws: AgentFailure.invalidRequest) {
                    try await run.respond(to: request, with: .answers([questions[0].id: [""] , questions[1].id: ["Example"]]))
                }
                #expect(await run.pendingRequests() == [request])
                var draft = AgentQuestionState(questions: questions)
                try draft.select("Red", for: questions[0].id)
                try draft.setText("Example", for: questions[1].id)
                try await run.respond(to: request, with: cancel ? .deny : .answers(try #require(draft.answers)))
                await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .deny) }
            }
            if case .turnEnded = event.kind { break }
        }
        let request = try #require(answered)
        await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .deny) }
        try await planWait { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete()
        try await run.shutdown()
        if let backend = backend as? CodexBackend { try await backend.shutdown() }
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func providerCancellationRejectsLateAnswers(provider: AgentProvider) async throws {
        let script = provider == .claude ? #"""
claude_init()
read()
emit({'type':'control_request','request_id':'q','request':{'subtype':'can_use_tool','tool_name':'AskUserQuestion','input':{'questions':[{'question':'Details?','options':[]}]}}})
emit({'type':'control_cancel_request','request_id':'q'})
emit({'type':'result','is_error':False})
done()
"""# : #"""
codex_init()
start_thread()
r=read()
emit({'id':r['id'],'result':{'turn':{'id':'turn-test'}}})
emit({'id':7,'method':'item/tool/requestUserInput','params':{'threadId':'thread-test','turnId':'turn-test','itemId':'q','isBlocking':True,'questions':[{'id':'q','question':'Details?','header':'Details','options':None}]}})
emit({'method':'serverRequest/resolved','params':{'threadId':'thread-test','requestId':7}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'completed','items':[]}}})
done()
"""#
        let fixture = try BackendExecutableFixture(script: script)
        defer { fixture.remove() }
        let backend: any AgentBackend = provider == .claude
            ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
            : CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "Ask"), willDeliver: {})
        var pending: AgentRequest?, resolved = false
        for try await event in run.events {
            if case .request(let request) = event.kind { pending = request }
            if case .requestResolved = event.kind {
                resolved = true
                let request = try #require(pending)
                await #expect(throws: AgentFailure.invalidRequest) {
                    try await run.respond(to: request, with: .answers([provider == .claude ? "Details?" : "q": ["Late"]]))
                }
            }
            if case .turnEnded = event.kind { break }
        }
        #expect(pending != nil)
        #expect(resolved)
        try await run.shutdown()
        if let backend = backend as? CodexBackend { try await backend.shutdown() }
    }
}

private func questionScript(provider: AgentProvider, cancel: Bool) -> String {
    let questions = #"[{'id':'color','header':'Color','question':'Color?','options':[{'label':'Red','description':'Warm'},{'label':'Blue','description':'Cool'}],'isOther':False},{'id':'detail','header':'Detail','question':'Details?','options':None,'isOther':True}]"#
    if provider == .claude {
        return "claude_init()\nread()\nquestions=" + questions + #"""

emit({'type':'control_request','request_id':'bad','request':{'subtype':'can_use_tool','tool_name':'AskUserQuestion','input':{'questions':[]}}})
assert read()['response']['subtype']=='error'
emit({'type':'control_request','request_id':'q','request':{'subtype':'can_use_tool','tool_name':'AskUserQuestion','input':{'questions':questions}}})
r=read()['response']
"""# + (cancel ? "\nassert r['subtype']=='error'" : "\nassert r['response']['updatedInput']['answers']=={'Color?':'Red','Details?':'Example'}") + "\nemit({'type':'result','is_error':False})\ndone()"
    }
    return "codex_init()\nstart_thread()\nr=read()\nemit({'id':r['id'],'result':{'turn':{'id':'turn-test'}}})\nquestions=" + questions + #"""

emit({'id':6,'method':'item/tool/requestUserInput','params':{'threadId':'thread-test','turnId':'turn-test','itemId':'bad','isBlocking':True,'questions':[]}})
assert read()['error']['code']==-32601
emit({'id':7,'method':'item/tool/requestUserInput','params':{'threadId':'thread-test','turnId':'turn-test','itemId':'q','isBlocking':False,'questions':questions}})
r=read()
assert r['id']==7
"""# + (cancel ? "\nassert r['error']['code']==-32601" : "\nassert r['result']=={'answers':{'color':{'answers':['Red']},'detail':{'answers':['Example']}}}") + "\nemit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'completed','items':[]}}})\ndone()"
}
