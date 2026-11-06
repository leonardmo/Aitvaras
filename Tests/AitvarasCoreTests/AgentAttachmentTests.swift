import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

struct AgentAttachmentTests {
    @Test func snapshotsBytesAndRejectsMissingLargeAndBinaryFiles() throws {
        let fixture = try BackendExecutableFixture(script: "done()")
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("notes.txt")
        #expect(throws: AgentAttachmentError.missingFile) { try AgentAttachment.read(source) }
        #expect(throws: AgentAttachmentError.missingFile) { try AgentAttachment.read(fixture.directory) }
        try Data("selected".utf8).write(to: source)
        let snapshot = try AgentAttachment.read(source)
        try Data("edited".utf8).write(to: source)
        try FileManager.default.removeItem(at: source)
        #expect(snapshot.data == Data("selected".utf8))
        #expect(snapshot.name == "notes.txt")
        try Data(repeating: 1, count: AgentAttachment.maximumBytes + 1).write(to: source)
        #expect(throws: AgentAttachmentError.tooLarge) { try AgentAttachment.read(source) }
        #expect(throws: AgentAttachmentError.unsupportedType) { try AgentAttachment(name: "archive.bin", data: Data([0, 1, 2])) }
        #expect(throws: AgentAttachmentError.unsupportedType) { try AgentAttachment(name: "broken.png", data: Data("garbage".utf8)) }
        #expect(throws: AgentAttachmentError.tooLarge) {
            try AgentAttachment(name: "big.txt", data: Data(repeating: 65, count: AgentAttachment.maximumBytes + 1))
        }
    }

    @Test func cancellationAndUnsupportedDeliveryDoNotCrossBarrier() async throws {
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AgentAttachment.read(URL(fileURLWithPath: "/missing.txt"))
        }
        await #expect(throws: CancellationError.self) { try await work.value }
        let pdf = try AgentAttachment(name: "notes.pdf", data: Data("%PDF-1.7".utf8))
        let fixture = try BackendExecutableFixture(script: "codex_init()\nstart_thread()\nwhile True: read()")
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        await #expect(throws: AgentAttachmentError.unsupportedType) {
            try await run.send(.init(text: "Read", attachments: [pdf]), willDeliver: { Issue.record("Unsupported input crossed delivery barrier") })
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await run.send(.init(text: "cancelled"), willDeliver: { Issue.record("Cancelled input crossed delivery barrier") })
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await run.shutdown(); try await backend.shutdown()
    }

    @Test func nativeEncodingsAndAggregateBounds() throws {
        let image = try AgentAttachment(name: "picture.png", data: attachmentPNG)
        let pdf = try AgentAttachment(name: "paper.pdf", data: Data("%PDF-1.7".utf8))
        let text = try AgentAttachment(name: "a\"b.txt", data: Data("hello\nworld".utf8))
        let input = AgentInput(text: "Read", attachments: [image, text, pdf])
        let blocks = try #require(input.claudeContent().arrayValue)
        #expect(blocks[1]["type"] == .string("image"))
        #expect(blocks[1]["source"]?["data"] == .string(attachmentPNG.base64EncodedString()))
        #expect(blocks[2]["text"]?.stringValue?.contains("a\\\"b.txt") == true)
        #expect(blocks[3]["type"] == .string("document"))
        let codex = try AgentInput(text: "Read", attachments: [image, text]).codexContent()
        #expect(codex.arrayValue?[1]["url"] == .string("data:image/png;base64," + attachmentPNG.base64EncodedString()))
        let imageOnly = AgentInput(text: "", attachments: [image])
        #expect(try imageOnly.claudeContent().arrayValue?.first?["type"] == .string("image"))
        #expect(try imageOnly.codexContent().arrayValue?.first?["type"] == .string("image"))
        var selection = AgentComposerSelection()
        let large = try AgentAttachment(name: "large.txt", data: Data(repeating: 65, count: AgentAttachment.maximumBytes))
        try selection.add(large)
        #expect(throws: AgentAttachmentError.tooLarge) { try selection.add(text) }
        selection = .init()
        for _ in 0..<AgentAttachment.maximumCount { try selection.add(text) }
        #expect(throws: AgentAttachmentError.tooMany) { try selection.add(text) }
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func attachmentsReachInitialAndFollowupFramesAndKeepJournal(provider: AgentProvider) async throws {
        let check = #"""
def check(content):
    assert content[0]=={'type':'text','text':'Read'}
    if 'source' in content[1]:
        assert content[1]['type']=='image' and content[1]['source']['media_type']=='image/png'
        assert base64.b64decode(content[1]['source']['data']).startswith(b'\x89PNG\r\n\x1a\n')
    else:
        assert content[1]['type']=='image' and content[1]['url'].startswith('data:image/png;base64,')
    assert content[2]=={'type':'text','text':'File "notes.txt":\nselected'}
"""#
        let script = provider == .claude ? #"""
claude_init()
check(read()['message']['content'])
emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'working'}}})
check(read()['message']['content'])
emit({'type':'result','uuid':'first-result','is_error':False})
emit({'type':'result','uuid':'second-result','is_error':False})
done()
"""# : #"""
codex_init()
start_thread()
r=read(); assert r['method']=='turn/start'; check(r['params']['input'])
emit({'id':r['id'],'result':{'turn':{'id':'active'}}})
r=read(); assert r['method']=='turn/steer'; check(r['params']['input'])
emit({'id':r['id'],'result':{'turnId':'active'}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'active','status':'completed','items':[]}}})
done()
"""#
        let fixture = try BackendExecutableFixture(script: check + "\n" + script)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: provider)
        let attachments = try [AgentAttachment(name: "image.png", data: attachmentPNG), AgentAttachment(name: "notes.txt", data: Data("selected".utf8))]
        let first = AgentInput(text: "Read", attachments: attachments), followup = AgentInput(text: "Read", attachments: attachments)
        try await manager.send(chatID: chat, provider: provider, input: first)
        try await waitAgentCondition { try stores.agentTurn(id: first.id)?.delivery == .acknowledged }
        let initial = try #require(try stores.agentEntries(chatID: chat).first { $0.id == first.id })
        #expect(initial.payloadJSON.flatMap(JSONValue.parse)?["followup"] == nil)
        try await manager.send(chatID: chat, provider: provider, input: followup)
        try await waitAgentCondition { try stores.agentTurn(id: followup.id)?.state == .completed }
        let entry = try #require(try stores.agentEntries(chatID: chat).first { $0.id == followup.id })
        let restored = try AgentInput.restoring(id: followup.id, text: entry.text, payload: entry.payloadJSON)
        #expect(restored == followup)
        try await waitAgentCondition { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test func safeRetryUsesSavedBytesAndProviderHandoverExcludesThem() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
assert read()['message']['content']==[{'type':'text','text':'Read'},{'type':'text','text':'File "notes.txt":\nselected'}]
emit({'type':'assistant','message':{'id':'reply','role':'assistant','content':[{'type':'text','text':'OK'}]}})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let auth = fixture.directory.appendingPathComponent("auth-status.json")
        try Data(#"{"loggedIn":false}"#.utf8).write(to: auth)
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        let input = AgentInput(text: "Read", attachments: [try AgentAttachment(name: "notes.txt", data: Data("selected".utf8))])
        await #expect(throws: AgentFailure.authRequired) { try await manager.send(chatID: chat, provider: .claude, input: input) }
        #expect(try stores.agentTurn(id: input.id)?.delivery == .prepared)
        try FileManager.default.removeItem(at: auth)
        try await manager.resendPrepared(turnID: input.id)
        try await waitAgentCondition { try stores.agentTurn(id: input.id)?.state == .completed }
        let other = AgentChatSession(chatID: chat, provider: .codex, cwd: fixture.directory.path, model: "default")
        try stores.saveAgentSession(other)
        let handover = try #require(try stores.agentContext(session: other))
        #expect(handover.text.contains("Read"))
        #expect(!handover.text.contains("selected"))
        #expect(!handover.text.contains("notes.txt"))
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test func navigationNeverTransfersAttachmentSelections() throws {
        var selections = AgentComposerSelections()
        let chat = UUID(), other = UUID()
        let file = try AgentAttachment(name: "notes.txt", data: Data("selected".utf8))
        try selections[chat, .claude].add(file)
        #expect(selections[chat, .codex].attachments.isEmpty)
        #expect(selections[other, .claude].attachments.isEmpty)
        #expect(selections[chat, .claude].attachments == [file])
    }

    @Test func failedSnapshotSavePreventsTextOnlyRetry() async throws {
        let fixture = try BackendExecutableFixture(script: "open('launched','w').close()\nclaude_init()\ndone()")
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        try await stores.db.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER failComposerSave BEFORE INSERT ON agentTranscriptEntry BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        let input = AgentInput(text: "Read", attachments: [try AgentAttachment(name: "notes.txt", data: Data("selected".utf8))])
        await #expect(throws: (any Error).self) { try await manager.send(chatID: chat, provider: .claude, input: input) }
        #expect(try stores.agentTurn(id: input.id)?.delivery == .prepared)
        try await stores.db.queue.write { try $0.execute(sql: "DROP TRIGGER failComposerSave") }
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.resendPrepared(turnID: input.id) }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("launched").path))
        #expect(throws: (any Error).self) { try AgentInput.restoring(id: input.id, text: input.text, payload: #"{"composer":{"attachments":"corrupt"}}"#) }
        #expect(throws: AgentFailure.invalidRequest) { try AgentInput.restoring(id: input.id, text: input.text, payload: "invalid JSON") }
        try await manager.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func frameLimitIsCheckedBeforeDelivery(provider: AgentProvider) async throws {
        let fixture = try BackendExecutableFixture(script: provider == .claude
            ? "claude_init()\nwhile True: read()" : "codex_init()\nstart_thread()\nwhile True: read()")
        defer { fixture.remove() }
        let backend: any AgentBackend = provider == .claude
            ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
            : CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        await #expect(throws: AgentAttachmentError.tooLarge) {
            try await run.send(.init(text: String(repeating: "\0", count: 200_000)), willDeliver: { Issue.record("Oversized frame crossed delivery barrier") })
        }
        try await run.shutdown()
        if let backend = backend as? CodexBackend { try await backend.shutdown() }
    }
}

private let attachmentPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
