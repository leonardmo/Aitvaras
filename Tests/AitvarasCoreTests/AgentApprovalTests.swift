import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite struct AgentApprovalTests {
    @Test func managedApprovalAuditBelongsToDurableActivityAndDeniesOnStop() async throws {
        let stores = try inMemoryStores()
        let chat = try agentStoreChat(stores).0.id
        let backend = ApprovalBackend(provider: .claude)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        let input = AgentInput(text: "test")
        try await manager.send(chatID: chat, provider: .claude, input: input)
        let run = try #require(await backend.runs.first)
        let request = await run.offer()
        try await approvalWait { await manager.approvalSuggestions().count == 1 }
        let offered = try #require(try stores.activityEvents(runID: input.id).first)
        #expect(offered.kind == .suggestionOffered)
        #expect(offered.runID == input.id)
        #expect(try stores.activityRun(id: input.id)?.referenceID == chat.uuidString)
        #expect(try await manager.stop(activityRunID: input.id))
        #expect(await manager.approvalSuggestions().isEmpty)
        #expect(try await manager.state(chatID: chat).pendingCards.isEmpty)
        await #expect(throws: (any Error).self) {
            try await manager.respond(chatID: chat, to: request, with: .allow(updatedInput: nil))
        }
        #expect(await run.responses == [.deny])
        #expect(try stores.activityEvents(runID: input.id).contains { $0.kind == .confirmationDenied })
        try await manager.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func suggestionsAndInlineCardsShareScopeAndReserveConcurrentReplies(provider: AgentProvider) async throws {
        let stores = try inMemoryStores()
        let first = try agentStoreChat(stores, provider: provider).0.id, second = try agentStoreChat(stores, provider: provider).0.id
        let backend = ApprovalBackend(provider: provider)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        var updates = await manager.approvalUpdates().makeAsyncIterator()
        #expect(await updates.next()?.isEmpty == true)
        for chat in [first, second] {
            try await manager.send(chatID: chat, provider: provider, input: .init(text: "test"))
        }
        let runs = await backend.runs
        let one = await runs[0].offer(), two = await runs[1].offer()
        try await approvalWait { await manager.approvalSuggestions().count == 2 }
        let suggestions = await manager.approvalSuggestions()
        #expect(await updates.next()?.count == 2)
        #expect(Set(suggestions.map(\.id)).count == 2) // identical native IDs, different runs
        #expect(suggestions.first { $0.chatID == first }?.request == one)
        #expect(suggestions.first { $0.chatID == second }?.request == two)
        #expect(ChatSidebarStatus(try await manager.state(chatID: first)) == .needsYou)
        await #expect(throws: AgentFailure.invalidRequest) {
            try await manager.respond(chatID: second, to: one, with: .allow(updatedInput: nil))
        }
        let clicks = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { try await manager.respond(chatID: first, to: one, with: .allow(updatedInput: nil)); return true }
                    catch { return false }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(clicks.filter { $0 }.count == 1)
        #expect(await runs[0].responses == [.allow(updatedInput: nil)])
        #expect(try await manager.state(chatID: first).pendingCards.isEmpty)
        #expect(try await manager.state(chatID: second).pendingCards == [two])
        try await manager.respond(chatID: second, to: two, with: .deny)
        #expect(await runs[1].responses == [.deny])
        #expect(await manager.approvalSuggestions().isEmpty)
        #expect(ChatSidebarStatus(try await manager.state(chatID: second)) == .running)
        let audit = try stores.recentActivity(limit: 20)
        #expect(audit.count == 4)
        #expect(audit.allSatisfy { $0.runID != nil && $0.connectorID == "agent" })
        #expect(audit.allSatisfy { JSONValue.parse($0.detailJSON ?? "")?["chatID"] != nil })
        #expect(!audit.contains { ($0.detailJSON ?? "").contains("echo example") })
        try await manager.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex], ["permission", "permissions", "plan", "questions"])
    func unansweredCardsStayPendingUntilAnsweredOrStopped(provider: AgentProvider, kind: String) async throws {
        for stop in [false, true] {
            let stores = try inMemoryStores()
            let run = ApprovalRun(provider: provider)
            let coordinator = AgentActionCoordinator(run: run, mode: .ask, provenance: .init(chatID: UUID())) {
                _ = try stores.record($0)
            }
            try await coordinator.send(.init(text: "test"), willDeliver: {})
            let requestKind: AgentRequest.Kind = switch kind {
            case "permission": .permission(.init(name: "Bash", input: .object(["command": .string("echo example")])))
            case "permissions": .permissions(.object([:]))
            case "plan": .plan("Create an example file")
            default: .questions([.init(id: "q", prompt: "Choose a name")])
            }
            let request = await run.offer(requestKind)
            try await approvalWait { await coordinator.pendingRequests() == [request] }
            // The former expiry test injected a 60 ms timeout. Wait beyond
            // that deadline without adding a ten-minute delay to this suite.
            try await Task.sleep(for: .milliseconds(120))
            #expect(await coordinator.pendingRequests() == [request])
            #expect(await run.responses.isEmpty)
            #expect(try stores.recentActivity(limit: 10).map(\.kind) == [.suggestionOffered])

            let response: AgentResponse
            if stop {
                try await coordinator.interrupt()
                response = kind == "questions" ? .unsupported : .deny
            } else {
                response = kind == "questions" ? .answers(["q": ["Example"]]) : .allow(updatedInput: nil)
                try await coordinator.respond(to: request, with: response)
            }
            #expect(await coordinator.pendingRequests().isEmpty)
            #expect(await run.responses == [response])
            let audit = try stores.recentActivity(limit: 10)
            #expect(audit.count == 2)
            #expect(audit.contains { $0.kind == (stop ? .confirmationDenied : .toolExecuted) })
            await #expect(throws: AgentFailure.invalidRequest) {
                try await coordinator.respond(to: request, with: .deny)
            }
            try await coordinator.shutdown()
        }
    }

    @Test(arguments: ["provider-cancel", "restart", "reply-rejected"])
    func resolvedCardsCannotBeApprovedAgain(reason: String) async throws {
        let stores = try inMemoryStores()
        let run = ApprovalRun(provider: .claude)
        let input = AgentInput(text: "test")
        let coordinator = AgentActionCoordinator(run: run, mode: .ask, provenance: .init(chatID: UUID())) { _ = try stores.record($0) }
        try await coordinator.send(input, willDeliver: {})
        let request = await run.offer()
        try await approvalWait { await coordinator.pendingRequests().count == 1 }
        switch reason {
        case "provider-cancel": await run.resolve(request)
        case "restart": try await coordinator.shutdown()
        default:
            await run.rejectReplies()
            await #expect(throws: AgentFailure.offline) {
                try await coordinator.respond(to: request, with: .allow(updatedInput: nil))
            }
        }
        try await approvalWait { await coordinator.pendingRequests().isEmpty }
        await #expect(throws: AgentFailure.invalidRequest) { try await coordinator.respond(to: request, with: .allow(updatedInput: nil)) }
        if reason == "provider-cancel" { #expect(await run.responses.isEmpty) }
        else if reason != "reply-rejected" { try await approvalWait { await run.responses == [.deny] } }
        try await approvalWait { try stores.recentActivity(limit: 10).count == 2 }
        let audit = try stores.recentActivity(limit: 10)
        #expect(audit.count == 2)
        #expect(audit.contains { $0.kind == (reason == "reply-rejected" ? .toolExecuted : .confirmationDenied) })
        if reason == "restart" {
            let fresh = AgentActionCoordinator(run: ApprovalRun(provider: .claude), mode: .ask,
                provenance: .init(chatID: UUID())) { _ in }
            #expect(await fresh.pendingRequests().isEmpty)
            await #expect(throws: AgentFailure.invalidRequest) { try await fresh.respond(to: request, with: .allow(updatedInput: nil)) }
            try await fresh.shutdown()
        }
        try await coordinator.shutdown()
    }

    @Test func failedDurableApprovalWriteDeniesAndClearsAllCards() async throws {
        let stores = try inMemoryStores()
        let chat = try agentStoreChat(stores).0.id
        let backend = ApprovalBackend(provider: .claude)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        try await manager.send(chatID: chat, provider: .claude, input: .init(text: "test"))
        let run = try #require(await backend.runs.first)
        let request = await run.offer()
        try await approvalWait { try await manager.state(chatID: chat).pendingCards.count == 1 }
        try await stores.db.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER testApprovalAuditFailure BEFORE INSERT ON activityEvent BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        await #expect(throws: (any Error).self) {
            try await manager.respond(chatID: chat, to: request, with: .allow(updatedInput: nil))
        }
        try await approvalWait { await run.responses == [.deny] }
        #expect(try await manager.state(chatID: chat).pendingCards.isEmpty)
        #expect(await manager.approvalSuggestions().isEmpty)
        let restarted = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        #expect(try await restarted.state(chatID: chat).pendingCards.isEmpty)
        await #expect(throws: AgentSessionManagerError.staleRun) {
            try await restarted.respond(chatID: chat, to: request, with: .allow(updatedInput: nil))
        }
        try await manager.shutdown(); try await restarted.shutdown()
    }

    @Test func approvalPresentationShowsCommandsFilesAndScopedPermissions() throws {
        let scope = AgentEventScope(runID: UUID())
        let command = AgentRequest(id: .integer(1), scope: scope, kind: .permission(.init(name: "commandExecution",
            input: .object(["command": .string("echo example"), "threadId": .string("hidden"), "reason": .string("Run a check")]))))
        #expect(command.presentation.title == "Run command?")
        #expect(command.presentation.detail == "echo example")
        #expect(command.presentation.reason == "Run a check")
        let file = AgentActionPresentation(tool: .init(name: "Write", input: .object(["file_path": .string("example.txt"), "content": .string("hello")])))
        #expect(file.title == "Change file?")
        #expect(file.detail == "example.txt")
        let permissions = AgentRequest(id: .integer(2), scope: scope, kind: .permissions(.object([
            "permissions": .object(["network": .object(["enabled": .bool(true)]), "fileSystem": .object([
                "write": .array([.string("/tmp/example")]), "entries": .array([.object([
                    "access": .string("read"), "path": .object(["type": .string("path"), "path": .string("/tmp/input")])])])])])])))
        #expect(permissions.presentation.detail == "Network access for this turn\nWrite: /tmp/example\nRead: /tmp/input")
    }

    @Test(arguments: ["zsh", "bash", "sh", "/bin/zsh", "/usr/bin/bash"])
    func plainShellWrappersArePresentationOnly(shell: String) {
        let command = "\(shell) -lc 'touch example.txt'"
        let tool = AgentTool(name: "Bash", input: .object(["command": .string(command)]))
        #expect(AgentActionPresentation(tool: tool).detail == "touch example.txt")
        #expect(AgentActionPresentation.toolSummary(tool, finished: false, isError: false) == "Running touch example.txt")
        #expect(AgentActionPresentation.toolSummary(tool, finished: true, isError: false) == "Ran touch example.txt")
        #expect(tool.input["command"] == .string(command))
        #expect(AgentTranscriptContent.display(tool.input).contains(command))
    }

    @Test(arguments: [
        "/bin/zsh -lc 'echo one' extra", "/bin/zsh -c 'echo one'", "fish -lc 'echo one'",
        "env sh -lc 'echo one'", "/custom/sh -lc 'echo one'", "sh -lc 'echo one' && echo two",
        #"sh -lc "echo $HOME""#, #"sh -lc "echo `pwd`""#, #"sh -lc "echo \$x""#,
        "sh -lc 'unterminated", "echo example"
    ]) func complexCommandsKeepTheirFullSpelling(command: String) {
        #expect(AgentActionPresentation.displayCommand(command) == command)
    }

    @Test func claudeFileToolsUsePlainVerbsAndDoubleQuotedCommandsUnwrap() {
        for (name, running, finished) in [("Read", "Reading", "Read"), ("Edit", "Editing", "Edited"), ("Write", "Writing", "Wrote")] {
            let tool = AgentTool(name: name, input: .object(["file_path": .string("example.txt")]))
            #expect(AgentActionPresentation.toolSummary(tool, finished: false, isError: false) == "\(running) example.txt")
            #expect(AgentActionPresentation.toolSummary(tool, finished: true, isError: false) == "\(finished) example.txt")
        }
        #expect(AgentActionPresentation.displayCommand(#"/bin/bash -lc "printf 'hi' > example.txt""#) == "printf 'hi' > example.txt")
    }

    @Test func opencodeBuiltinToolsUsePlainSummaries() throws {
        let cases: [(String, JSONValue, String, String)] = [
            ("question", .object(["questions": .array([.object(["header": .string("Approval"), "question": .string("Continue?")])])]), "Asked: Approval", "Asked: Approval"),
            ("read", .object(["filePath": .string("example.txt")]), "Reading example.txt", "Read example.txt"),
            ("edit", .object(["filePath": .string("example.txt")]), "Editing example.txt", "Edited example.txt"),
            ("write", .object(["filePath": .string("example.txt")]), "Writing example.txt", "Wrote example.txt"),
            ("grep", .object(["pattern": .string("example")]), "Searching for example", "Searched for example"),
            ("glob", .object(["pattern": .string("*.swift")]), "Searching for *.swift", "Searched for *.swift"),
            ("list", .object(["path": .string("Sources")]), "Listing Sources", "Listed Sources"),
            ("webfetch", .object(["url": .string("https://example.invalid")]), "Fetching https://example.invalid", "Fetched https://example.invalid"),
            ("todo", .object(["todos": .array([])]), "Updating tasks", "Updated tasks"),
            ("todowrite", .object(["todos": .array([])]), "Updating tasks", "Updated tasks"),
            ("todoread", .object([:]), "Reading tasks", "Read tasks"),
            ("task", .object(["description": .string("Inspect files")]), "Delegating: Inspect files", "Delegated: Inspect files")
        ]
        for (name, input, running, finished) in cases {
            let tool = AgentTool(name: name, input: input)
            #expect(AgentActionPresentation.toolSummary(tool, finished: false, isError: false) == running)
            #expect(AgentActionPresentation.toolSummary(tool, finished: true, isError: false) == finished)
            #expect(AgentActionPresentation.toolSummary(tool, finished: true, isError: true).hasPrefix("Failed to"))
        }
    }

    @Test func codexFileApprovalUsesItemPathsAndDenialUsesAvailableDecision() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
start_thread()
r=read()
emit({'id':r['id'],'result':{'turn':{'id':'turn-test'}}})
p={'threadId':'thread-test','turnId':'turn-test','itemId':'file-test'}
item={'id':'file-test','type':'fileChange','changes':[{'path':'example.txt','kind':{'type':'add'},'diff':'+hello'}],'status':'inProgress'}
emit({'method':'item/started','params':dict(p,item=item)})
emit({'id':1,'method':'item/fileChange/requestApproval','params':p})
assert read()['result']['decision']=='decline'
p['itemId']='command-test'
p['command']='echo example'
p['availableDecisions']=['accept','cancel']
emit({'id':2,'method':'item/commandExecution/requestApproval','params':p})
assert read()['result']['decision']=='cancel'
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'interrupted','items':[]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        let coordinator = AgentActionCoordinator(run: run, mode: .ask, provenance: .init(chatID: UUID())) { _ in }
        try await coordinator.send(.init(text: "test"), willDeliver: {})
        var details: [String] = []
        for try await event in coordinator.events {
            if case .request(let request) = event.kind {
                details.append(request.presentation.detail)
                try await coordinator.respond(to: request, with: .deny)
            }
            if case .turnEnded = event.kind { break }
        }
        #expect(details == ["example.txt", "echo example"])
        try await Task.sleep(for: .milliseconds(20))
        try fixture.assertComplete()
        try await coordinator.shutdown(); try await backend.shutdown()
    }

    @Test(arguments: ["claude", "codex"])
    func executableCancellationClearsPendingWhileTurnRemainsRunning(provider: String) async throws {
        let claude = #"""
claude_init()
read()
emit({'type':'control_request','request_id':'approval','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'echo example'}}})
# Hold cancellation until the test has observed the card.
while not os.path.exists('cancel'): time.sleep(0.005)
emit({'type':'control_cancel_request','request_id':'approval'})
done()
"""#
        let codex = #"""
codex_init()
start_thread()
r=read()
emit({'id':r['id'],'result':{'turn':{'id':'turn-test'}}})
emit({'id':7,'method':'item/commandExecution/requestApproval','params':{'threadId':'thread-test','turnId':'turn-test','itemId':'tool-test','command':'echo example'}})
while not os.path.exists('cancel'): time.sleep(0.005)
emit({'method':'serverRequest/resolved','params':{'threadId':'thread-test','requestId':7}})
while True:
    r=read()
    if r.get('method')=='turn/interrupt':
        emit({'id':r['id'],'result':{}})
        break
done()
"""#
        let fixture = try BackendExecutableFixture(script: provider == "claude" ? claude : codex)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let choice: AgentProvider = provider == "claude" ? .claude : .codex
        let chat = try agentStoreChat(stores, provider: choice, cwd: fixture.directory.path).0.id
        let backend: any AgentBackend = provider == "claude"
            ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
            : CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        try await manager.send(chatID: chat, provider: choice, input: .init(text: "test"))
        try await approvalWait { await manager.approvalSuggestions().count == 1 }
        let request = try #require(await manager.approvalSuggestions().first?.request)
        try Data().write(to: fixture.directory.appendingPathComponent("cancel"))
        try await approvalWait { await manager.approvalSuggestions().isEmpty }
        #expect(try await manager.state(chatID: chat).isRunning)
        #expect(ChatSidebarStatus(try await manager.state(chatID: chat)) == .running)
        await #expect(throws: AgentFailure.invalidRequest) { try await manager.respond(chatID: chat, to: request, with: .deny) }
        try await manager.shutdown()
        if let backend = backend as? CodexBackend { try await backend.shutdown() }
    }
}

private actor ApprovalRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let provider: AgentProvider
    private var input: UUID?
    private var reject = false
    private(set) var responses: [AgentResponse] = []
    init(provider: AgentProvider) {
        self.provider = provider; (events, continuation) = AsyncThrowingStream.makeStream()
    }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        try await willDeliver(); self.input = input.id
    }
    func offer(_ kind: AgentRequest.Kind = .permission(.init(name: "Bash",
        input: .object(["command": .string("echo example")])))) -> AgentRequest {
        let scope = AgentEventScope(runID: id, session: .init(provider: provider, profile: "test", nativeID: "session-test"), inputID: input, turnID: "turn-test", itemID: "tool-test")
        let request = AgentRequest(id: .integer(1), scope: scope, kind: kind)
        continuation.yield(.init(scope: scope, kind: .request(request)))
        return request
    }
    func resolve(_ request: AgentRequest) { continuation.yield(.init(scope: request.scope, kind: .requestResolved(request.id))) }
    func rejectReplies() { reject = true }
    func respond(to request: AgentRequest, with response: AgentResponse) throws {
        if reject { throw AgentFailure.offline }
        responses.append(response)
    }
    func setMode(_ mode: AgentMode) {}
    func interrupt() {}
    func shutdown() { continuation.finish() }
}

private actor ApprovalBackend: AgentBackend {
    nonisolated let provider: AgentProvider
    private(set) var runs: [ApprovalRun] = []
    init(provider: AgentProvider) { self.provider = provider }
    func status() -> AgentStatus { .init(installed: true, authentication: .subscription, capabilities: [.approvals]) }
    func models() -> [AgentModel] { [] }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
    func start(_ configuration: AgentSessionConfiguration) -> any AgentRun {
        let run = ApprovalRun(provider: provider); runs.append(run); return run
    }
}

private func approvalWait(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<200 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AgentFailure.offline
}
