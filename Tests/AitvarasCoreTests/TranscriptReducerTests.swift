import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

@Suite struct TranscriptReducerTests {
    @Test(arguments: ["completed", "nonzero", "failure", "disconnect", "missing", "wrong-turn", "in-progress", "malformed", "timeout"])
    func missingCodexToolCompletionReconcilesBeforeTurnEnd(scenario: String) async throws {
        let fixture = try BackendExecutableFixture(script: "scenario = '\(scenario)'\n" + #"""
codex_init()
start_thread()
r=read()
assert r['method']=='turn/start'
emit({'id':r['id'],'result':{'turn':{'id':'turn-test'}}})
item={'id':'command-test','type':'commandExecution','command':'printf example','cwd':root,
      'commandActions':[],'status':'inProgress','aggregatedOutput':None,'exitCode':None,'durationMs':None}
p={'threadId':'thread-test','turnId':'turn-test','itemId':item['id']}
emit({'method':'item/started','params':dict(p,item=item)})
emit({'id':'approval-test','method':'item/commandExecution/requestApproval','params':dict(p,command=item['command'],cwd=root)})
assert read()=={'id':'approval-test','result':{'decision':'accept'}}
message={'id':'reply','type':'agentMessage','text':'Done'}
terminal={'threadId':'thread-test','turn':{'id':'turn-test','status':'completed','items':[message]}}
emit({'method':'turn/completed','params':terminal})
r=read()
assert r['method']=='thread/read'
assert r['params']=={'threadId':'thread-test','includeTurns':True}
if scenario=='disconnect':
    open('done','w').close()
    sys.exit(7)
finished=dict(item,status='completed',aggregatedOutput='example',exitCode=7 if scenario=='nonzero' else 0,durationMs=12)
result={'thread':{'id':'thread-test','turns':[
    {'id':'older-turn','items':[dict(finished,aggregatedOutput='wrong turn')]},
    {'id':'turn-test','items':[finished,finished,dict(finished,id='unstarted'),message]}]}}
if scenario=='failure':
    emit({'id':r['id'],'error':{'code':-32603,'message':'History unavailable'}})
elif scenario!='timeout':
    if scenario=='missing': result['thread']['turns'][1]['items']=[]
    elif scenario=='wrong-turn': result['thread']['turns'].pop()
    elif scenario=='in-progress': finished['status']='inProgress'
    elif scenario=='malformed': finished.pop('status')
    emit({'id':r['id'],'result':result})
# A duplicate turn end cannot launch another read or finish twice.
emit({'method':'turn/completed','params':terminal})
next_turn=read()
assert next_turn['method']=='turn/start'
if scenario=='timeout':
    # A reply after the deadline must not leak into this next turn.
    emit({'id':r['id'],'result':result})
emit({'method':'item/completed','params':dict(p,item=finished)})
emit({'method':'turn/completed','params':terminal})
emit({'id':next_turn['id'],'result':{'turn':{'id':'next-turn'}}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'next-turn','status':'completed','items':[]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let session = AgentChatSession(chatID: UUID(), provider: .codex, cwd: fixture.directory.path, model: "test")
        let raw = try await backend.start(session.configuration)
        let run = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: session.chatID), audit: { _ in })
        let input = AgentInput(text: "Run the example command")
        var state = ChatState(chatID: session.chatID)
        state.begin(input, session: session, outputID: UUID())
        let started = ContinuousClock.now
        try await run.send(input, willDeliver: {})
        let events = try await collectTurn(run)
        #expect(ContinuousClock.now - started < .seconds(5))
        var completions = 0
        for event in events {
            state.reduce(event, newEntryID: UUID())
            if case .toolFinished = event.kind {
                completions += 1
                #expect(state.isRunning)
                #expect(event.scope.itemID == "command-test")
                #expect(event.scope.turnID == "turn-test")
            }
        }
        let confirmed = scenario == "completed" || scenario == "nonzero"
        #expect(events.last?.kind == .turnEnded(.completed))
        #expect(state.outcome == .completed)
        #expect(!state.isRunning)
        #expect(completions == (confirmed ? 1 : 0))
        #expect(state.entries.filter { $0.kind == "assistant" }.map(\.text) == ["Done"])
        let row = try #require(state.entries.first { $0.kind == "tool" })
        #expect(state.entries.filter { $0.kind == "tool" }.count == 1)
        let payload = try #require(row.payloadJSON.flatMap(JSONValue.parse))
        #expect(payload["finished"] == .bool(true))
        #expect(payload["completionUnconfirmed"] == .bool(!confirmed))
        #expect(payload["isError"] == .bool(scenario == "nonzero"))
        let summary = AgentActionPresentation.toolSummary(.init(name: row.text, input: payload["input"] ?? .null),
            finished: true, isError: scenario == "nonzero", completionUnconfirmed: !confirmed)
        #expect(summary == (scenario == "nonzero" ? "Failed to run printf example"
            : confirmed ? "Ran printf example" : "Ended without a result: printf example"))
        if confirmed {
            #expect(payload["output"]?["exitCode"] == .number(scenario == "nonzero" ? 7 : 0))
            #expect(payload["output"]?["durationMs"] == .number(12))
            #expect(AgentTranscriptContent.display(payload["output"] ?? .null)
                == "Exit code: \(scenario == "nonzero" ? 7 : 0)\nexample")
        }
        #expect((row.presentationIdentifier == "chat.tool.completed") == (scenario == "completed"))
        if scenario != "disconnect" {
            // Recovery failure, including timeout, must leave the shared wire usable.
            try await run.send(.init(text: "Next turn"), willDeliver: {})
            let next = try await collectTurn(run)
            #expect(next.last?.kind == .turnEnded(.completed))
            #expect(!next.contains { if case .toolFinished = $0.kind { true } else { false } })
        }
        try await Task.sleep(for: .milliseconds(20))
        try fixture.assertComplete()
        try await run.shutdown()
        try await backend.shutdown()
    }

    @Test(arguments: [true, false])
    func recordedAskCommandCompletionSurvivesManagerPersistence(completionDelivered: Bool) async throws {
        let fixture: BackendExecutableFixture
        if completionDelivered {
            fixture = try BackendExecutableFixture(provider: "codex", name: "write-ask")
        } else {
            // Fault injection: keep the real approval and summary-only turn end,
            // but lose the command's item/completed notification.
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/agents/codex/write-ask.jsonl")
            let recording = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { line in
                let frame = JSONValue.parse(String(line))
                return !(frame?["method"]?.stringValue == "item/completed"
                    && frame?["params"]?["item"]?["type"]?.stringValue == "commandExecution")
            }.joined(separator: "\n")
            fixture = try BackendExecutableFixture(script: "recording = base64.b64decode('\(Data(recording.utf8).base64EncodedString())').decode()\n"
                + BackendExecutableFixture.replay)
        }
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, original) = try agentStoreChat(stores, provider: .codex, cwd: fixture.directory.path)
        var session = original
        session.model = "gpt-6-luna"
        try stores.saveAgentSession(session)
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend },
            audit: { _ = try stores.record($0) })
        let updates = try await manager.updates(chatID: chat.id)
        try await manager.send(chatID: chat.id, provider: .codex,
            input: .init(text: try fixture.prompt(provider: "codex", name: "write-ask")))
        var rowID: UUID?
        var approved = false
        var completedBeforeEnd = false
        for await state in updates {
            if let row = state.entries.first(where: { $0.kind == "tool" }) {
                if rowID == nil { rowID = row.id }
                #expect(row.id == rowID)
                if row.presentationIdentifier == "chat.tool.completed" && state.isRunning {
                    completedBeforeEnd = true
                }
            }
            if !approved, let request = state.pendingCards.first {
                approved = true
                try await manager.respond(chatID: chat.id, to: request, with: .allow(updatedInput: nil))
            }
            if state.outcome != nil { break }
        }
        #expect(approved)
        #expect(completedBeforeEnd == completionDelivered)
        let saved = try #require(stores.agentEntries(chatID: chat.id).first { $0.id == rowID })
        #expect((saved.presentationIdentifier == "chat.tool.completed") == completionDelivered)
        let payload = try #require(saved.payloadJSON.flatMap(JSONValue.parse))
        #expect(payload["finished"] == .bool(true))
        #expect(AgentActionPresentation.toolSummary(.init(name: saved.text, input: payload["input"] ?? .null),
            finished: payload["finished"]?.boolValue == true, isError: payload["isError"]?.boolValue == true,
            completionUnconfirmed: payload["completionUnconfirmed"]?.boolValue == true)
            == (completionDelivered ? "Ran printf 'hi' > a.txt && echo marker > out.txt"
                : "Ended without a result: printf 'hi' > a.txt && echo marker > out.txt"))
        try await Task.sleep(for: .milliseconds(20))
        try fixture.assertComplete()
        try await manager.shutdown()
        try await backend.shutdown()
    }

    @Test(arguments: [AgentTurnOutcome.completed, .interrupted, .failed(.unknown)])
    func endedTurnsNeverLeaveRunningToolRows(outcome: AgentTurnOutcome) throws {
        var fixture = TranscriptFixture()
        fixture.emit(.toolStarted(.init(name: "commandExecution", input: .object(["command": .string("touch example.txt")]))), item: "shell")
        let rowID = try #require(fixture.state.entries.last?.id)
        fixture.emit(.turnEnded(outcome), item: "turn")
        let row = try #require(fixture.state.entries.first { $0.id == rowID })
        let payload = try #require(row.payloadJSON.flatMap(JSONValue.parse))
        #expect(payload["finished"] == .bool(true))
        #expect(AgentActionPresentation.toolSummary(.init(name: row.text, input: payload["input"] ?? .null),
            finished: true, isError: false, completionUnconfirmed: payload["completionUnconfirmed"]?.boolValue == true)
            == "Ended without a result: touch example.txt")
        // Turn completion alone is not proof of a successful shell command.
        #expect(row.presentationIdentifier != "chat.tool.completed")
        #expect(fixture.state.tools.allSatisfy { $0.isFinished })
        let endedEntries = fixture.state.entries
        fixture.state.begin(.init(text: "Next turn"), session: .init(chatID: fixture.state.chatID,
            provider: .codex, cwd: "/tmp", model: "test"), outputID: UUID())
        #expect(Array(fixture.state.entries.prefix(endedEntries.count)) == endedEntries)
    }

    @Test func interleavedToolsAccumulateOutputAndKeepIdentity() throws {
        var fixture = TranscriptFixture()
        fixture.emit(.toolStarted(.init(name: "Bash", input: .object(["command": .string("echo first")]))), item: "one")
        let first = try #require(fixture.state.entries.last?.id)
        fixture.emit(.toolStarted(.init(name: "Read", input: .object(["file_path": .string("example.txt")]))), item: "two")
        fixture.emit(.toolOutput(.string("first ")), item: "one")
        fixture.emit(.toolOutput(.string("second")), item: "one")
        #expect(fixture.state.tools.first?.output == .string("first second"))
        fixture.emit(.toolFinished(output: .string("read failed"), isError: true), item: "two")
        fixture.emit(.toolFinished(output: .string("canonical output"), isError: false), item: "one")
        fixture.emit(.toolFinished(output: .string("canonical output"), isError: false), item: "one")
        fixture.emit(.toolOutput(.string("late duplicate")), item: "one")
        #expect(fixture.state.entries.filter { $0.kind == "tool" }.count == 2)
        let raw = try #require(fixture.state.entries.first { $0.id == first }?.payloadJSON)
        let payload = try #require(JSONValue.parse(raw))
        #expect(payload["output"] == .string("canonical output"))
        #expect(fixture.state.tools.last?.isError == true)
        #expect(fixture.state.tools.allSatisfy { $0.isFinished })
    }

    @Test func interleavedMessagesAndDuplicateCompletionDoNotOverwriteAnotherReply() throws {
        var fixture = TranscriptFixture()
        fixture.emit(.textDelta("first"), item: "one")
        let first = fixture.state.entries.last?.id
        fixture.emit(.textDelta("second"), item: "two")
        let second = fixture.state.entries.last?.id
        fixture.emit(.message(id: "one", role: "assistant", text: "first complete"), item: "one")
        fixture.emit(.message(id: "one", role: "assistant", text: "first complete"), item: "one")
        fixture.emit(.textDelta(" complete"), item: "two")
        fixture.emit(.message(id: "two", role: "assistant", text: "second complete"), item: "two")
        let entries = fixture.state.entries.filter { $0.kind == "assistant" }
        #expect(entries.map(\.id) == [first, second])
        #expect(entries.map(\.text) == ["first complete", "second complete"])
        #expect(entries.map(\.nativeMessageID) == ["one", "two"])
    }

    @Test func thinkingAndToolPreviewsAreBoundedAndFinalThinkingReplacesDeltas() throws {
        var fixture = TranscriptFixture()
        let huge = String(repeating: "🐉", count: 20_000)
        fixture.emit(.thinkingDelta("partial"), item: "reason")
        let thinkingID = fixture.state.entries.last?.id
        fixture.emit(.thinkingCompleted("complete"), item: "reason")
        fixture.emit(.thinkingCompleted("complete"), item: "reason")
        #expect(fixture.state.entries.last?.id == thinkingID)
        #expect(fixture.state.thinking == "complete")
        fixture.emit(.thinkingDelta(huge), item: "reason")
        fixture.emit(.toolStarted(.init(name: "Write", input: .object(["content": .string(huge)]))), item: "tool")
        fixture.emit(.toolInputDelta(huge), item: "tool")
        fixture.emit(.toolOutput(.string(huge)), item: "tool")
        fixture.emit(.toolOutput(.string("extra")), item: "tool")
        #expect(fixture.state.thinking.utf8.count <= AgentTranscriptContent.maximumBytes)
        let tool = try #require(fixture.state.tools.first)
        for text in [tool.partialInput, tool.output?.stringValue ?? "", AgentTranscriptContent.display(tool.tool?.input ?? .null)] {
            #expect(text.utf8.count <= AgentTranscriptContent.maximumBytes)
            #expect(text.hasSuffix(AgentTranscriptContent.truncation))
            #expect(!text.contains("�"))
        }
        let raw = try #require(fixture.state.entries.last?.payloadJSON)
        #expect(JSONValue.parse(raw) != nil)
    }

    @Test(arguments: ["claude", "codex"])
    func recordedTurnsReduceWithoutDuplicatedToolsOrEmptyAssistantRows(provider: String) async throws {
        let name = provider == "claude" ? "accept-edits" : "write-onreq"
        let fixture = try BackendExecutableFixture(provider: provider, name: name)
        defer { fixture.remove() }
        let backend: any AgentBackend = provider == "claude"
            ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
            : CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let session = AgentChatSession(chatID: UUID(), provider: provider == "claude" ? .claude : .codex,
            cwd: fixture.directory.path, model: provider == "claude" ? "default" : "gpt-6-luna", mode: .acceptEdits)
        let run = try await backend.start(session.configuration)
        let input = AgentInput(text: try fixture.prompt(provider: provider, name: name))
        var state = ChatState(chatID: session.chatID)
        state.begin(input, session: session, outputID: UUID())
        try await run.send(input, willDeliver: {})
        for try await event in run.events {
            state.reduce(event, newEntryID: UUID())
            if case .request(let request) = event.kind { try await run.respond(to: request, with: .continueHook) }
            if case .turnEnded = event.kind { break }
        }
        #expect(state.outcome == .completed)
        #expect(!state.tools.isEmpty)
        #expect(state.tools.allSatisfy { $0.isFinished })
        #expect(state.entries.filter { $0.kind == "tool" }.count == state.tools.count)
        #expect(state.entries.filter { $0.kind == "assistant" }.allSatisfy { !$0.text.isEmpty })
        try await Task.sleep(for: .milliseconds(20))
        try fixture.assertComplete()
        try await run.shutdown()
        if let backend = backend as? CodexBackend { try await backend.shutdown() }
    }

    @Test func recordedCodexApprovalCompletesTheSameRowBeforeTurnEnds() async throws {
        let fixture = try BackendExecutableFixture(provider: "codex", name: "write-ask")
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let session = AgentChatSession(chatID: UUID(), provider: .codex, cwd: fixture.directory.path, model: "gpt-6-luna")
        let raw = try await backend.start(session.configuration)
        let run = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: session.chatID), audit: { _ in })
        let input = AgentInput(text: try fixture.prompt(provider: "codex", name: "write-ask"))
        var state = ChatState(chatID: session.chatID)
        state.begin(input, session: session, outputID: UUID())
        try await run.send(input, willDeliver: {})
        var rowIDs: [String: UUID] = [:]
        var completions = 0
        for try await event in run.events {
            state.reduce(event, newEntryID: UUID())
            if case .toolStarted = event.kind {
                let nativeID = try #require(event.scope.itemID)
                let row = try #require(state.entries.last { $0.kind == "tool" })
                rowIDs[nativeID] = row.id
                #expect(row.presentationIdentifier == "chat.entry.\(row.id)")
            }
            if case .request(let request) = event.kind {
                try await run.respond(to: request, with: .allow(updatedInput: nil))
            }
            if case .toolFinished = event.kind {
                completions += 1
                let nativeID = try #require(event.scope.itemID)
                let rowID = try #require(rowIDs[nativeID])
                let row = try #require(state.entries.first { $0.id == rowID })
                let payload = try #require(row.payloadJSON.flatMap(JSONValue.parse))
                #expect(state.isRunning)
                #expect(payload["itemID"] == .string(nativeID))
                #expect(payload["finished"] == .bool(true))
                #expect(row.presentationIdentifier == "chat.tool.completed")
                #expect(AgentActionPresentation.toolSummary(.init(name: row.text, input: payload["input"] ?? .null),
                    finished: true, isError: false) == "Ran printf 'hi' > a.txt && echo marker > out.txt")
                // Persistence/decoding must retain the value used by SwiftUI/AX.
                let restored = try JSONDecoder().decode(AgentTranscriptEntry.self, from: JSONEncoder().encode(row))
                #expect(restored.presentationIdentifier == "chat.tool.completed")
            }
            if case .turnEnded = event.kind { break }
        }
        #expect(completions == 1)
        #expect(state.entries.filter { $0.kind == "tool" }.count == 1)
        try await Task.sleep(for: .milliseconds(20))
        try fixture.assertComplete()
        try await run.shutdown()
        try await backend.shutdown()
    }

    @Test func failedToolNeverAdvertisesSuccessfulCompletion() throws {
        var fixture = TranscriptFixture()
        fixture.emit(.toolStarted(.init(name: "Bash", input: .object(["command": .string("false")]))), item: "one")
        fixture.emit(.toolFinished(output: .string("failed"), isError: true), item: "one")
        let row = try #require(fixture.state.entries.last)
        #expect(row.presentationIdentifier == "chat.entry.\(row.id)")
        #expect(AgentActionPresentation.toolSummary(.init(name: row.text, input: .object(["command": .string("false")])),
            finished: true, isError: true) == "Failed to run false")
    }

    @Test func claudeStreamsToolArgumentsAndMultipleTextBlocks() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
emit({'type':'stream_event','event':{'type':'message_start','message':{'id':'message-test'}}})
emit({'type':'stream_event','event':{'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}}})
emit({'type':'stream_event','event':{'type':'content_block_delta','index':0,'delta':{'text':'first'}}})
emit({'type':'assistant','message':{'id':'message-test','role':'assistant','content':[{'type':'text','text':'first'}]}})
emit({'type':'stream_event','event':{'type':'content_block_start','index':1,'content_block':{'type':'tool_use','id':'tool-test','name':'Read','input':{}}}})
emit({'type':'stream_event','event':{'type':'content_block_delta','index':1,'delta':{'partial_json':'{"file_path":'}}})
emit({'type':'stream_event','event':{'type':'content_block_delta','index':1,'delta':{'partial_json':'"example.txt"}'}}})
emit({'type':'assistant','message':{'id':'message-test','role':'assistant','content':[{'type':'tool_use','id':'tool-test','name':'Read','input':{'file_path':'example.txt'}}]}})
emit({'type':'stream_event','event':{'type':'content_block_start','index':2,'content_block':{'type':'text','text':''}}})
emit({'type':'stream_event','event':{'type':'content_block_delta','index':2,'delta':{'text':'second'}}})
emit({'type':'assistant','message':{'id':'message-test','role':'assistant','content':[{'type':'text','text':'second'}]}})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        let input = AgentInput(text: "test")
        let session = AgentChatSession(chatID: UUID(), provider: .claude, cwd: fixture.directory.path, model: "test")
        var state = ChatState(chatID: session.chatID)
        state.begin(input, session: session, outputID: UUID())
        try await run.send(input, willDeliver: {})
        var partials: [String] = []
        for try await event in run.events {
            state.reduce(event, newEntryID: UUID())
            if case .toolInputDelta = event.kind { partials.append(state.tools.first?.partialInput ?? "") }
            if case .turnEnded = event.kind { break }
        }
        #expect(partials == [#"{"file_path":"#, #"{"file_path":"example.txt"}"#])
        #expect(state.entries.filter { $0.kind == "assistant" }.map(\.text) == ["first\nsecond"])
        #expect(state.tools.first?.tool?.input["file_path"] == .string("example.txt"))
        try await Task.sleep(for: .milliseconds(20))
        try fixture.assertComplete()
        try await run.shutdown()
    }
}

private struct TranscriptFixture {
    var state: ChatState
    let input = AgentInput(text: "test")
    let runID = UUID()
    init() {
        let chat = UUID()
        state = ChatState(chatID: chat)
        state.begin(input, session: .init(chatID: chat, provider: .codex, cwd: "/tmp", model: "test"), outputID: UUID())
    }
    mutating func emit(_ kind: AgentEvent.Kind, item: String) {
        state.reduce(.init(scope: .init(runID: runID, inputID: input.id, itemID: item), kind: kind), newEntryID: UUID())
    }
}
