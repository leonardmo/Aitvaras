import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentReviewRegressionTests {
    @Test func mcpStatusProbeUsesNoUserPromptAndDropsSecretConfiguration() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert sys.argv[sys.argv.index('--model')+1]=='opus'
assert sys.argv[sys.argv.index('--effort')+1]=='medium'
claude_init()
r=read(); assert r['type']=='control_request' and r['request']['subtype']=='mcp_status'
emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{'mcpServers':[{'name':'docs','status':'connected','source':'user','scope':'user','transport':'http','serverInfo':{'name':'Example'},'config':{'headers':{'Authorization':'synthetic-status-secret'}},'tools':[{'name':'search'}]}]}}})
open('done','w').close()
assert sys.stdin.readline()==''
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: fixture.directory.path)])
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment, mcpPolicy: mcpTestPolicy(stores, root: fixture.directory))
        let snapshot = try await backend.setup(directory: fixture.directory, projectID: project.id)
        #expect(snapshot.servers == [.init(name: "docs", status: .connected, source: "user")])
        #expect(snapshot.serversAvailable)
        #expect(!String(describing: snapshot).contains("synthetic-status-secret"))
        let payloads = try await stores.db.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM workspaceAgentSetup").map { String(describing: $0) }.joined()
                + Row.fetchAll(db, sql: "SELECT * FROM activityEvent").map { String(describing: $0) }.joined()
        }
        #expect(!payloads.contains("synthetic-status-secret"))
        try fixture.assertComplete()
    }

    @Test func refreshingSetupReusesAHealthyChatAndKeepsItsTurnState() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
assert read()['message']['content']=='first'
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'session-example','mcp_servers':[]})
emit({'type':'assistant','uuid':'answer-first','message':{'role':'assistant','content':[{'type':'text','text':'first answer'}]}})
emit({'type':'result','uuid':'result-first','is_error':False})
r=read(); assert r['request']['subtype']=='mcp_status'
emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{'mcpServers':[{'name':'docs','status':'needs-auth','source':'user','config':{'token':'synthetic-status-secret'}}]}}})
assert read()['message']['content']=='second'
emit({'type':'assistant','uuid':'answer-second','message':{'role':'assistant','content':[{'type':'text','text':'second answer'}]}})
emit({'type':'result','uuid':'result-second','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        var iterator = run.events.makeAsyncIterator()
        try await run.send(.init(text: "first"), willDeliver: {})
        while let event = try await iterator.next() { if case .turnEnded = event.kind { break } }
        let setup = try await backend.setup(directory: fixture.directory, projectID: nil)
        #expect(setup.servers.first?.status == .needsAuth)
        try await run.send(.init(text: "second"), willDeliver: {})
        var second = false
        while let event = try await iterator.next() {
            #expect(!String(describing: event).contains("synthetic-status-secret"))
            if case .message(_, "assistant", "second answer") = event.kind { second = true }
            if case .turnEnded = event.kind { break }
        }
        #expect(second)
        try fixture.assertComplete(); try await run.shutdown()
    }

    @Test func malformedStatusIsUnavailableAndDoesNotInventConnections() {
        var snapshot = AgentSetupSnapshot(provider: .claude)
        #expect(throws: AgentFailure.invalidRequest) { try snapshot.claudeMCPStatus(.object([:])) }
        #expect(!snapshot.serversAvailable)
        #expect(snapshot.servers.isEmpty)
    }

    @Test func revokingApprovalDoesNotDenyTheServer() async throws {
        let stores = try inMemoryStores(), project = try stores.createWorkspaceProject(title: "Example")
        let fingerprint = String(repeating: "a", count: 64)
        try stores.editAgentSetup(projectID: project.id, edit: .approve(name: "echo", fingerprint: fingerprint))
        try stores.editAgentSetup(projectID: project.id, edit: .revoke(name: "echo"))
        let setup = try stores.workspaceAgentSetup(projectID: project.id)
        #expect(setup.approvedProjectServers.isEmpty)
        #expect(setup.approvedProjectServerFingerprints.isEmpty)
        #expect(setup.deniedProjectServers.isEmpty)
        #expect(try stores.activity(since: .distantPast).count == 2)
    }

    @Test func completionAndQuoteInsertionsLeaveTheCaretAfterAllUTF16Text() throws {
        let trigger = try #require(AgentComposerTrigger.detect("/sho"))
        let inserted = try #require(trigger.selecting("/shout", in: "/sho"))
        #expect(inserted == "/shout ")
        #expect(AgentComposerCaret.afterInsertion(inserted) == NSRange(location: 7, length: 0))
        let quote = AgentConversationText.appending(AgentConversationText.quote("Example 🐉\nSecond line"), to: "")
        #expect(quote.hasSuffix("\n"))
        #expect(AgentComposerCaret.afterInsertion(quote).location == (quote as NSString).length)
        #expect(AgentComposerCaret.afterInsertion(quote).length == 0)
        let commands = AgentCommandCatalog.withConversationCommands([.init(name: "shout", description: "Repeat"), .init(name: "btw", description: "Native command")])
        #expect(commands.filter { $0.name == "btw" } == [AgentCommandCatalog.sideQuestion])
        #expect(AgentCommandCatalog.sideQuestion.insertion == "/btw")
        #expect(AgentCommandCatalog.sideQuestion.argumentHint == "<question>")
        #expect(AgentCommandCatalog.sideQuestion.description == "Ask a side question without adding it to the chat")
    }

    @Test func commandSourceGroupsUseReportedMetadataAndPreserveUnknownSources() throws {
        let commands = try AgentCommandCatalog.claude(JSONValue.parse(#"{"commands":[{"name":"shout","source":"project"},{"name":"review","scope":"user"},{"name":"plugin:check","source":"plugin"},{"name":"help","source":"builtin"},{"name":"other"}]}"#)!)
        #expect(commands.first { $0.name == "shout" }?.group == .project)
        #expect(commands.first { $0.name == "review" }?.group == .user)
        #expect(commands.first { $0.name == "plugin:check" }?.group == .plugin)
        #expect(commands.first { $0.name == "help" }?.group == .builtIn)
        #expect(commands.first { $0.name == "other" }?.group == .unknown)
        let old = try JSONDecoder().decode(AgentCommand.self, from: Data(#"{"name":"shout","description":"Repeat"}"#.utf8))
        #expect(old.group == .unknown)
    }

    @Test func slashCommandMarkupIsNormalizedOnlyForCompleteEnvelopes() throws {
        let markup = "<command-message>shout</command-message> <command-name>/shout</command-name> <command-args>quiet little words</command-args>"
        #expect(ClaudeCommandText.display(markup) == "/shout quiet little words")
        #expect(AgentTranscriptEntry(chatID: UUID(), provider: .claude, kind: "user", text: markup).displayText == "/shout quiet little words")
        #expect(AgentTranscriptEntry(chatID: UUID(), provider: .claude, kind: "assistant", text: markup).displayText == markup)
        #expect(ClaudeCommandText.display("<command-name>/shout</command-name><command-args>&lt;words&gt; &amp; more</command-args>") == "/shout <words> & more")
        #expect(ClaudeCommandText.display("Example " + markup) == "Example " + markup)
        #expect(ClaudeCommandText.display("<command-name>/shout</command-name>") == "/shout")
        let fixture = try AgentExecutableFixture("exit 0"); defer { fixture.remove() }
        let project = fixture.directory.appendingPathComponent("projects/example")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sid = UUID().uuidString, user = UUID().uuidString, assistant = UUID().uuidString
        let records: [JSONValue] = [
            .object(["type": .string("user"), "uuid": .string(user), "sessionId": .string(sid), "cwd": .string(fixture.directory.path),
                     "message": .object(["role": .string("user"), "content": .string(markup)])]),
            .object(["type": .string("assistant"), "uuid": .string(assistant), "sessionId": .string(sid), "cwd": .string(fixture.directory.path),
                     "message": .object(["role": .string("assistant"), "stop_reason": .string("end_turn"), "content": .array([.object(["type": .string("text"), "text": .string("Answer")])])])])]
        try Data((records.map(\.jsonString).joined(separator: "\n") + "\n").utf8).write(to: project.appendingPathComponent(sid + ".jsonl"))
        let reader = ClaudeNativeHistory(projectsDirectory: project.deletingLastPathComponent(), profile: "test")
        #expect(try reader.list(folder: fixture.directory, cursor: nil).items.first?.title == "/shout quiet little words")
        let page = try reader.history(session: .init(provider: .claude, profile: "test", nativeID: sid), cursor: nil)
        #expect(page.items.first?.kind == .message(id: user, role: "user", text: "/shout quiet little words"))
    }

    @Test func reorderingCoalescedAnswersKeepsIdentityAndRejectsBogusIDsAtomically() throws {
        let stores = try inMemoryStores(), (chat, session) = try agentStoreChat(stores)
        let first = AgentTranscriptEntry(chatID: chat.id, provider: session.provider, kind: "user", text: "First", sessionID: session.id)
        let answer = AgentTranscriptEntry(chatID: chat.id, provider: session.provider, kind: "assistant", text: "Answer", sessionID: session.id)
        let next = AgentTranscriptEntry(chatID: chat.id, provider: session.provider, kind: "user", text: "Next", sessionID: session.id)
        for row in [first, answer, next] { _ = try stores.saveAgentEntry(row) }
        try stores.orderAgentEntries(chatID: chat.id, ids: [first.id, next.id, answer.id])
        #expect(try stores.agentEntries(chatID: chat.id).map(\.id) == [first.id, next.id, answer.id])
        #expect(throws: AgentStoreError.identityConflict) { try stores.orderAgentEntries(chatID: chat.id, ids: [first.id, UUID()]) }
        #expect(throws: AgentStoreError.invalidValue) { try stores.orderAgentEntries(chatID: chat.id, ids: [first.id, first.id]) }
        #expect(try stores.agentEntries(chatID: chat.id).map(\.id) == [first.id, next.id, answer.id])
    }

    @Test func claudeDefaultsUseTheAliasAndPreserveSavedExplicitChoices() throws {
        let old = AgentChatSession(chatID: UUID(), provider: .claude, cwd: "/tmp/example", model: "default")
        let updated = ChatSettings.restoring(old, models: [])
        #expect(updated.model == "opus"); #expect(updated.effort == "medium")
        var explicit = old; explicit.model = "saved-model"; explicit.effort = "high"
        #expect(ChatSettings.restoring(explicit, models: [.init(id: "other", name: "Other")]) == explicit)
        let models = ChatSettings.claudeModels([.init(id: "default", name: "Default (recommended)"), .init(id: "other", name: "Other")])
        #expect(models.first?.id == "opus"); #expect(models.first?.name == "Opus (newest)")
        #expect(models.map(\.id) == ["opus", "other"])
        let sid = AgentSessionID(provider: .claude, profile: "test", nativeID: UUID().uuidString)
        let arguments = try ClaudeSideQuestion.arguments(.init(directory: URL(fileURLWithPath: "/tmp/example"), resume: sid, model: "default"))
        #expect(Array(arguments.suffix(4)) == ["--model", "opus", "--effort", "medium"])
    }
}
