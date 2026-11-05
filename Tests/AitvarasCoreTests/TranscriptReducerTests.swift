import Foundation
import Testing
@testable import AitvarasAgents

@Suite struct TranscriptReducerTests {
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
