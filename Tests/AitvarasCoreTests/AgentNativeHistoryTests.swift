import Foundation
import Testing
import AitvarasCore
@testable import AitvarasAgents

@Suite struct AgentNativeHistoryTests {
    @Test func claudeReadsRecordedContentWithoutCLIOrSDK() async throws {
        let fixture = try NativeHistoryFixture()
        defer { fixture.remove() }
        // Recorded assistant message content inside a persisted JSONL envelope.
        let recording = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agents/claude/ask-mode.jsonl")
        let assistant = try #require(try String(contentsOf: recording, encoding: .utf8).split(separator: "\n")
            .compactMap { JSONValue.parse(String($0)) }.first { $0["type"]?.stringValue == "assistant"
                && $0["message"]?["content"]?.arrayValue?.contains(where: { $0["type"]?.stringValue == "text" }) == true })
        let content = try #require(assistant["message"])
        try fixture.write(records: [fixture.record("user", text: "Example question"),
            .object(["type": .string("future-record"), "payload": .object([:])]),
            .object(["type": .string("assistant"), "uuid": .string("reply"), "message": content,
                     "sessionId": .string(fixture.id), "cwd": .string(fixture.root.path), "version": .string("2.1.300")])])
        let backend = ClaudeBackend(environment: ["HOME": fixture.root.path, "PATH": ""],
                                    overrides: ["CLAUDE_CONFIG_DIR": fixture.root.path])
        let sessions = try await backend.listSessions(folder: fixture.root, cursor: nil)
        #expect(sessions.items.count == 1)
        #expect(sessions.items[0].sourceVersion == "2.1.300")
        #expect(sessions.items[0].archived == nil)
        let page = try await backend.readHistory(session: sessions.items[0].id, cursor: nil)
        try #require(page.items.count == 2)
        #expect(page.items[0].kind == .message(id: "user", role: "user", text: "Example question"))
        #expect(page.items[1].scope.itemID == "reply")
        await #expect(throws: AgentFailure.unsupported) {
            try await backend.nativeSessions(folder: nil, cursor: nil, archived: true)
        }
        let browser = NativeBackendSessionReader(provider: .claude, backend: backend)
        #expect(await browser.capabilities().state == .ready)
        #expect(try await browser.listSessions(cursor: nil, archived: false).sessions.count == 1)
        #expect(try await browser.readSession(id: fixture.id, directory: fixture.root.path, cursor: nil).messages.count == 2)
    }

    @Test func claudePaginationUnknownBlocksAndChangedHistory() throws {
        let fixture = try NativeHistoryFixture()
        defer { fixture.remove() }
        var records = (0..<55).map { fixture.record("user", text: "Message \($0)", id: "message-\($0)") }
        records.append(.object(["type": .string("assistant"), "uuid": .string("blocks"),
            "message": .object(["content": .array([
                .object(["type": .string("thinking"), "thinking": .string("private reasoning")]),
                .object(["type": .string("text"), "text": .string("one")]),
                .object(["type": .string("future-block")]),
                .object(["type": .string("text"), "text": .string("two")])])])]))
        try fixture.write(records: records)
        let first = try fixture.reader.history(session: fixture.session, cursor: nil)
        let cursor = try #require(first.nextCursor)
        let last = try fixture.reader.history(session: fixture.session, cursor: cursor)
        #expect(last.items.count == 6)
        #expect(last.nextCursor == nil)
        #expect(last.items.last?.kind == .message(id: "blocks", role: "assistant", text: "one\ntwo"))
        records.append(fixture.record("user", text: "external continuation", id: "new"))
        try fixture.write(records: records)
        #expect(throws: AgentNativeHistoryError.staleCursor) { try fixture.reader.history(session: fixture.session, cursor: cursor) }
        #expect(throws: AgentNativeHistoryError.invalidCursor) { try fixture.reader.history(session: fixture.session, cursor: "garbage") }
        #expect(throws: AgentFailure.invalidRequest) {
            try fixture.reader.history(session: .init(provider: .claude, profile: "other", nativeID: fixture.id), cursor: nil)
        }
    }

    @Test func claudeSessionPagesIgnoreSubagentsAndBindCursorsToFolders() throws {
        let fixture = try NativeHistoryFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for index in 1...51 {
            let id = String(format: "00000000-0000-4000-8000-%012d", index)
            let record = JSONValue.object(["type": .string("user"), "uuid": .string("message"),
                "sessionId": .string(id), "cwd": .string(fixture.root.path), "version": .string("2.1.300"),
                "message": .object(["content": .string("Example chat")])])
            try (record.jsonString + "\n").write(to: fixture.file.deletingLastPathComponent().appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
        }
        let subagents = fixture.file.deletingLastPathComponent().appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try "broken".write(to: subagents.appendingPathComponent("agent.jsonl"), atomically: true, encoding: .utf8)
        let first = try fixture.reader.list(folder: fixture.root, cursor: nil)
        #expect(first.items.count == 50)
        let cursor = try #require(first.nextCursor)
        let last = try fixture.reader.list(folder: fixture.root, cursor: cursor)
        #expect(last.items.count == 1)
        #expect(last.nextCursor == nil)
        #expect(try fixture.reader.list(folder: fixture.root.appendingPathComponent("unrelated"), cursor: nil).items.isEmpty)
        #expect(throws: AgentNativeHistoryError.invalidCursor) { try fixture.reader.list(folder: nil, cursor: cursor) }
    }

    @Test func codexHistoryPagesRejectChangesBetweenReads() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
for index in range(3):
    r=read()
    assert r['method']=='thread/read'
    items=[{'type':'agentMessage','id':'item-'+str(i),'text':'Reply '+str(i)} for i in range(55)]
    if index==2: items[0]['text']='changed'
    if index==2: open('done','w').close()
    emit({'id':r['id'],'result':{'thread':{'id':'native','turns':[{'id':'turn','items':items}]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let session = AgentSessionID(provider: .codex, profile: "default", nativeID: "native")
        let first = try await backend.readHistory(session: session, cursor: nil)
        #expect(first.items.count == 50)
        let cursor = try #require(first.nextCursor)
        let last = try await backend.readHistory(session: session, cursor: cursor)
        #expect(last.items.count == 5)
        #expect(last.nextCursor == nil)
        await #expect(throws: AgentNativeHistoryError.staleCursor) { try await backend.readHistory(session: session, cursor: cursor) }
        try fixture.assertComplete()
        try await backend.shutdown()
    }

    @Test func missingCorruptTruncatedAndDuplicateHistoryNeverClaimCompleteness() throws {
        let fixture = try NativeHistoryFixture()
        defer { fixture.remove() }
        #expect(try fixture.reader.list(folder: nil, cursor: nil).items.isEmpty)
        #expect(throws: AgentNativeHistoryError.notFound) { try fixture.reader.history(session: fixture.session, cursor: nil) }
        try fixture.write(records: [fixture.record("user", text: "one")])
        let bytes = try Data(contentsOf: fixture.file)
        try (bytes + Data("{\"type\":".utf8)).write(to: fixture.file)
        #expect(throws: AgentNativeHistoryError.incompleteHistory) { try fixture.reader.history(session: fixture.session, cursor: nil) }
        try (bytes + Data("broken\n".utf8)).write(to: fixture.file)
        #expect(throws: AgentNativeHistoryError.malformedHistory) { try fixture.reader.list(folder: nil, cursor: nil) }
        try fixture.write(records: [fixture.record("user", text: "one"), fixture.record("user", text: "duplicate")])
        #expect(throws: AgentNativeHistoryError.malformedHistory) { try fixture.reader.history(session: fixture.session, cursor: nil) }
        try fixture.write(records: [fixture.record("user", text: "")])
        #expect(try fixture.reader.list(folder: nil, cursor: nil).items.first?.title == "Claude chat")
        #expect(try fixture.reader.history(session: fixture.session, cursor: nil).items.isEmpty)
    }

    @Test func codexUsesReadOnlyHistoryRPCsAndNativeArchivePagination() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
for archived,cursor in [(False,None),(False,'next'),(True,None)]:
    r=read()
    assert r['method']=='thread/list'
    assert r['params']['archived']==archived
    assert r['params'].get('cursor')==cursor
    assert r['params']['modelProviders']==['openai']
    emit({'id':r['id'],'result':{'data':[{'id':'thread-'+str(archived),'cwd':root,'name':'' if archived else 'Native chat','modelProvider':'openai','cliVersion':'0.166.0-alpha.6'}], 'nextCursor':'next' if cursor is None and not archived else None}})
r=read()
assert r['method']=='thread/read'
assert r['params']=={'threadId':'thread-False','includeTurns':True}
# Item shapes match the 0.166.0-alpha.6 generated schema and recordings.
open('done','w').close()
emit({'id':r['id'],'result':{'thread':{'id':'thread-False','historyMode':'legacy','turns':[{'id':'turn','itemsView':'full','items':[
    {'type':'userMessage','id':'user','content':[{'type':'text','text':'one'},{'type':'text','text':'two'}]},
    {'type':'futureItem','id':'future'}, {'type':'agentMessage','id':'reply','text':'Answer'}]}]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let first = try await backend.listSessions(folder: fixture.directory, cursor: nil)
        #expect(first.nextCursor == "next")
        #expect(first.items.first?.sourceVersion == "0.166.0-alpha.6")
        #expect(try await backend.listSessions(folder: fixture.directory, cursor: first.nextCursor).nextCursor == nil)
        let archived = try await backend.nativeSessions(folder: nil, cursor: nil, archived: true)
        #expect(archived.items.first?.archived == true)
        #expect(archived.items.first?.title == "Codex chat")
        let page = try await backend.readHistory(session: first.items[0].id, cursor: nil)
        #expect(page.items.map(\.kind) == [.message(id: "user", role: "user", text: "one\ntwo"), .message(id: "reply", role: "assistant", text: "Answer")])
        try fixture.assertComplete()
        try await backend.shutdown()
    }

    @Test func codexUnavailableAndMalformedResponses() async throws {
        let unavailable = CodexBackend(executable: URL(fileURLWithPath: "/tmp/missing-native-provider-\(UUID())"), environment: ["PATH": ""])
        await #expect(throws: AgentFailure.notInstalled) { try await unavailable.listSessions(folder: URL(fileURLWithPath: "/tmp"), cursor: nil) }
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
for result in [{}, {'data':[], 'nextCursor':'same'}, {'thread':{'id':'wrong','turns':[]}}, {'thread':{'id':'native','historyMode':'paginated','turns':[]}}]:
    r=read()
    if result.get('thread',{}).get('historyMode')=='paginated': open('done','w').close()
    emit({'id':r['id'],'result':result})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        await #expect(throws: AgentNativeHistoryError.malformedHistory) { try await backend.nativeSessions(folder: nil, cursor: nil, archived: false) }
        await #expect(throws: AgentNativeHistoryError.invalidCursor) { try await backend.nativeSessions(folder: nil, cursor: "same", archived: false) }
        let session = AgentSessionID(provider: .codex, profile: "default", nativeID: "native")
        await #expect(throws: AgentNativeHistoryError.malformedHistory) { try await backend.readHistory(session: session, cursor: nil) }
        await #expect(throws: AgentFailure.unsupported) { try await backend.readHistory(session: session, cursor: nil) }
        await #expect(throws: AgentFailure.invalidRequest) { try await backend.readHistory(session: .init(provider: .codex, profile: "other", nativeID: "native"), cursor: nil) }
        try fixture.assertComplete()
        try await backend.shutdown()
    }
}

struct NativeHistoryFixture {
    let root: URL
    let id = "00000000-0000-4000-8000-000000000001"
    var session: AgentSessionID { .init(provider: .claude, profile: "default", nativeID: id) }
    var file: URL { root.appendingPathComponent("projects/example/\(id).jsonl") }
    var reader: ClaudeNativeHistory { .init(projectsDirectory: root.appendingPathComponent("projects")) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-history-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func record(_ role: String, text: String, id: String = "user") -> JSONValue {
        .object(["type": .string(role), "uuid": .string(id), "sessionId": .string(self.id), "cwd": .string(root.path),
                 "version": .string("2.1.300"), "message": .object(["role": .string(role), "content": .string(text)])])
    }
    func write(records: [JSONValue]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (records.map(\.jsonString).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
