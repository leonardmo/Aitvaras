import Foundation
import Darwin
import Testing
import GRDB
import AitvarasCore
import AitvarasAgents
@testable import AitvarasStore

@Suite(.timeLimit(.minutes(2))) struct ClaudeProviderProfileTests {
    @Test func migrationPreservesExistingChatsSessionsEntriesAndJournals() throws {
        let root = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("store.sqlite")
        var chat: WorkspaceChat
        let session: AgentChatSession, entries: [AgentTranscriptEntry], turn: AgentJournalTurn
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let created = try agentStoreChat(stores)
            chat = try #require(try stores.workspaceChat(id: created.0.id)); session = created.1
            let input = AgentInput(text: "Saved question")
            try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
            _ = try stores.saveAgentEntry(.init(id: input.id, chatID: chat.id, provider: .claude, kind: "user", text: input.text, sessionID: session.id))
            _ = try stores.saveAgentEntry(.init(chatID: chat.id, provider: .claude, kind: "assistant", text: "Saved answer", sessionID: session.id))
            try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown)
            try stores.advanceAgentDelivery(id: input.id, to: .acknowledged)
            try stores.finishAgentTurn(id: input.id, state: .completed)
            chat = try #require(try stores.workspaceChat(id: chat.id))
            entries = try stores.agentEntries(chatID: chat.id)
            turn = try #require(try stores.agentTurn(id: input.id))
        }
        // Reconstruct the immediately preceding shape. Foreign keys are checked
        // by the production migration after its transactional table replacement.
        do {
            var config = Configuration(); config.foreignKeysEnabled = false
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            try queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE oldSession AS SELECT id, chatID, provider, host, profile, nativeID,
                        cwd, model, effort, mode, instructions, additionalRootsJSON, forkOrigin FROM agentChatSession;
                    DROP TRIGGER agentTurnChat;
                    DROP TABLE agentChatSession;
                    ALTER TABLE oldSession RENAME TO agentChatSession;
                    CREATE TRIGGER agentTurnChat BEFORE INSERT ON agentTurn
                    WHEN NOT EXISTS (SELECT 1 FROM agentChatSession WHERE id = NEW.sessionID AND chatID = NEW.chatID)
                    BEGIN SELECT RAISE(ABORT, 'Turn must belong to its chat session'); END;
                    DROP TABLE agentProviderProfile;
                    DELETE FROM grdb_migrations WHERE identifier = 'v35-claude-provider-profiles';
                    """)
            }
        }
        for _ in 0..<2 {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let profiles = try stores.claudeProfiles()
            #expect(profiles.count == 1)
            #expect(profiles.first?.id == AgentProviderProfile.defaultClaudeID)
            #expect(profiles.first?.configDirectory == nil)
            #expect(profiles.first?.defaultModel == "opus" && profiles.first?.defaultEffort == "medium")
            #expect(try stores.workspaceChat(id: chat.id) == chat)
            #expect(try stores.agentSession(chatID: chat.id, provider: .claude) == session)
            #expect(try stores.agentEntries(chatID: chat.id) == entries)
            #expect(try stores.agentTurn(id: turn.id) == turn)
            #expect(try stores.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
        }
    }

    @Test func createsPrivateLinksOnlyAndLeavesDefaultHomeUntouched() throws {
        let root = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("default")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ClaudeProfileDirectory.sharedNames { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
        // Opaque provider files must never be opened, linked or copied.
        try Data("synthetic private fixture".utf8).write(to: source.appendingPathComponent("credentials.fixture"))
        let original = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
        let id = UUID()
        let result = try ClaudeProfileDirectory.create(stateDirectory: root, defaultDirectory: source, id: id)
        #expect(result.path == root.appendingPathComponent("Providers/claude/" + id.uuidString).path)
        let attrs = try FileManager.default.attributesOfItem(atPath: result.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.path).sorted() == ClaudeProfileDirectory.sharedNames.sorted())
        for name in ClaudeProfileDirectory.sharedNames {
            let path = result.appendingPathComponent(name).path
            #expect(try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType == .typeSymbolicLink)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == source.appendingPathComponent(name).path)
            #expect(try Data(contentsOf: source.appendingPathComponent(name)) == Data(name.utf8))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() == original)
        #expect(throws: (any Error).self) { try ClaudeProfileDirectory.create(stateDirectory: root, defaultDirectory: source, id: id) }
    }

    @Test func missingDefaultAndSymlinkSubstitutionFailSafely() throws {
        let root = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try ClaudeProfileDirectory.create(stateDirectory: root, defaultDirectory: root.appendingPathComponent("missing"), id: UUID())
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.path).isEmpty)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("Providers"), withDestinationURL: outside)
        #expect(throws: ClaudeProfileDirectory.Failure.unsafeDirectory) {
            try ClaudeProfileDirectory.create(stateDirectory: state, defaultDirectory: outside, id: UUID())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func profilesValidateReorderAndRetainDeletedAccountHistory() throws {
        let stores = try inMemoryStores(), root = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try stores.createClaudeProfile(name: "Work", stateDirectory: root, defaultDirectory: root.appendingPathComponent("missing"))
        let second = try stores.createClaudeProfile(name: "Other", stateDirectory: root, defaultDirectory: root.appendingPathComponent("missing"))
        #expect(first.defaultModel == "opus" && first.defaultEffort == "medium")
        try stores.authorizeClaudeProfileSignIn(profile: first.nativeProfile)
        #expect(try stores.activity(since: .distantPast).contains { $0.summary == "Sign in to Claude profile" && $0.sourceID == "providerProfile:" + first.id.uuidString })
        let ids = [second.id, AgentProviderProfile.defaultClaudeID, first.id]
        try stores.reorderClaudeProfiles(ids: ids)
        #expect(try stores.claudeProfiles().map(\.id) == ids)
        #expect(throws: AgentStoreError.invalidValue) { try stores.reorderClaudeProfiles(ids: [first.id, first.id]) }
        var edited = first; edited.name = "Renamed"; try stores.saveClaudeProfile(edited)
        #expect(try stores.claudeProfile(nativeProfile: first.nativeProfile)?.name == "Renamed")
        let (chat, _) = try agentStoreChat(stores)
        let session = AgentChatSession(chatID: chat.id, provider: .claude, cwd: "/tmp", model: "opus", providerProfile: first.nativeProfile)
        try stores.saveAgentSession(session)
        try stores.setValues(["agent.claudeProfile.\(chat.id.uuidString)": first.nativeProfile])
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude)?.id == session.id)
        try stores.deleteClaudeProfile(id: first.id)
        #expect(try stores.selectedClaudeProfile(chatID: chat.id) == "default")
        #expect(try stores.agentSession(chatID: chat.id, choice: first.choice) == session)
        #expect(try stores.claudeProfile(nativeProfile: first.nativeProfile) == nil)
        #expect(throws: AgentStoreError.invalidValue) { try stores.authorizeClaudeProfileSignIn(profile: first.nativeProfile) }
        #expect(try stores.claudeProfile(nativeProfile: first.nativeProfile, includeDeleted: true)?.isDeleted == true)
        #expect(FileManager.default.fileExists(atPath: first.configDirectory!))
        #expect(throws: AgentStoreError.invalidValue) { try stores.deleteClaudeProfile(id: AgentProviderProfile.defaultClaudeID) }
        #expect(throws: AgentStoreError.invalidValue) { try stores.deleteClaudeProfile(id: UUID()) }
        #expect(throws: AgentStoreError.invalidValue) { try stores.createClaudeProfile(name: " ", stateDirectory: root, defaultDirectory: root) }
    }

    @Test func switchingInExistingAndNewChatsPersistsTheExactChoice() throws {
        let stores = try inMemoryStores()
        let (existing, original) = try agentStoreChat(stores)
        let profile = AgentProviderProfile(name: "Other account", configDirectory: "/tmp/example-account")
        try stores.saveClaudeProfile(profile)
        try stores.saveAgentSession(.init(chatID: existing.id, provider: .claude, cwd: "/tmp", model: "opus", providerProfile: profile.nativeProfile))
        try stores.selectAgentChoice(profile.choice, chatID: existing.id)
        #expect(try stores.agentSession(chatID: existing.id, provider: .claude)?.providerProfile == profile.nativeProfile)
        try stores.selectAgentChoice(.init(provider: .codex), chatID: existing.id)
        #expect(try stores.value(forKey: "agent.provider.\(existing.id.uuidString)") == "codex")
        try stores.selectAgentChoice(.init(provider: .claude), chatID: existing.id)
        #expect(try stores.agentSession(chatID: existing.id, provider: .claude)?.id == original.id)
        // A choice made before the first send creates no chat/session itself.
        try stores.selectAgentChoice(profile.choice, chatID: nil)
        #expect(try stores.value(forKey: "agent.lastProfile") == profile.choice.id)
        let newChat = try stores.createWorkspaceChat(projectID: existing.projectID, title: "New chat")
        try stores.selectAgentChoice(profile.choice, chatID: newChat.id, rememberRecent: true)
        #expect(try stores.selectedClaudeProfile(chatID: newChat.id) == profile.nativeProfile)
        #expect(try stores.agentSessions(chatID: newChat.id).isEmpty)
        #expect(throws: AgentStoreError.invalidValue) { try stores.selectAgentChoice(.init(provider: .claude, profile: UUID().uuidString), chatID: existing.id) }
        #expect(try stores.agentSession(chatID: existing.id, provider: .claude)?.id == original.id)
        try stores.deleteClaudeProfile(id: profile.id)
        #expect(throws: AgentStoreError.invalidValue) { try stores.selectAgentChoice(profile.choice, chatID: nil) }
        #expect(try stores.selectedClaudeProfile(chatID: newChat.id) == "default")
    }

    @Test func aNewAccountNeverInheritsThePreviousAccountsUsageWindow() {
        let chat = UUID()
        let a = AgentChatSession(chatID: chat, provider: .claude, cwd: "/tmp", model: "opus")
        let b = AgentChatSession(chatID: chat, provider: .claude, cwd: "/tmp", model: "opus", providerProfile: UUID().uuidString)
        var state = ChatState(chatID: chat)
        state.begin(.init(text: "First account"), session: a, outputID: UUID())
        state.reduce(.init(scope: .init(runID: UUID()), kind: .rateLimits([.init(id: "window", utilization: 0.8)])), newEntryID: UUID())
        #expect(state.rateLimits.first?.utilization == 0.8)
        state.end(.completed)
        state.begin(.init(text: "Second account"), session: b, outputID: UUID())
        #expect(state.rateLimits.isEmpty)
        state.reduce(.init(scope: .init(runID: UUID()), kind: .rateLimits([.init(id: "window", utilization: 0.2)])), newEntryID: UUID())
        #expect(state.rateLimits.first?.utilization == 0.2)
    }

    @Test func sixProfilesHaveStableIdentitiesAndThreeRecentSegments() {
        let profiles = (0..<6).map { AgentProviderProfile(name: "Account \($0)") }
        let all = profiles.map(\.choice) + [.init(provider: .codex), .init(provider: .local)]
        let selected = all[4]
        let inline = AgentProviderChoice.inlineChoices(all: all, recent: [all[5], all[1], all[5]], selected: selected)
        #expect(inline == [selected, all[5], all[1]])
        #expect(all.count == 8 && Set(all.map(\.id)).count == 8)
        #expect(all.allSatisfy { AgentProviderChoice(id: $0.id) == $0 })
        #expect(AgentProviderChoice(provider: .codex, profile: "ignored").profile == "default")
        #expect(AgentProviderChoice(provider: .local, profile: "ignored").profile == "default")
        #expect(AgentProviderChoice(id: "codex:invalid") == nil)
    }
}

private func profileTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("claude-profiles-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite(.timeLimit(.minutes(2))) struct ClaudeProfileLaunchTests {
    @Test(arguments: ["status", "signIn", "chat", "models", "catalog", "setup", "mcpLogin", "sideQuestion", "fork"], [false, true])
    func everyLaunchUsesTheChosenHome(surface: String, separate: Bool) async throws {
        let fixture = try BackendExecutableFixture(script: #"""
if sys.argv[1:3] in (['auth','login'], ['mcp','login']):
    print('https://login.example.invalid/authorize', flush=True)
    sys.exit(0)
if '--no-session-persistence' in sys.argv:
    sys.stdin.readline()
    emit({'type':'result','is_error':False,'result':'Side answer'})
    sys.exit(0)
request=read()
assert request['request']['subtype']=='initialize'
emit({'type':'control_response','response':{'subtype':'success','request_id':request['request_id'],'response':{'models':[{'value':'test-model'}],'commands':[]}}})
while True:
    request=read()
    if request.get('type')=='control_request':
        assert request['request']['subtype']=='mcp_status'
        emit({'type':'control_response','response':{'subtype':'success','request_id':request['request_id'],'response':{'mcpServers':[]}}})
    else:
        emit({'type':'result','is_error':False})
"""#)
        defer { fixture.remove() }
        let home = fixture.directory.appendingPathComponent("account")
        let expected = separate ? home.path : "unset"
        let log = fixture.directory.appendingPathComponent("launches.jsonl")
        let original = try String(contentsOf: fixture.executable, encoding: .utf8)
        let check = #"""
import os, sys, json
expected=os.environ['EXPECTED_CONFIG']
actual=os.environ.get('CLAUDE_CONFIG_DIR','unset')
assert actual==expected, 'wrong Claude home'
with open(os.environ['LAUNCH_LOG'],'a') as f:
    f.write(json.dumps({'args':sys.argv[1:],'home':actual})+'\n')
"""#
        try original.replacingOccurrences(of: "#!/usr/bin/python3\n", with: "#!/usr/bin/python3\n" + check + "\n")
            .write(to: fixture.executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.executable.path)
        let profile = separate ? UUID().uuidString : "default"
        let backend = ClaudeBackend(executable: fixture.executable,
            environment: fixture.environment.merging(["EXPECTED_CONFIG": expected, "LAUNCH_LOG": log.path, "CLAUDE_CONFIG_DIR": "/tmp/untrusted-inherited-home"]) { _, v in v },
            profile: profile, overrides: separate ? ["CLAUDE_CONFIG_DIR": home.path] : [:], probeDirectory: fixture.directory)
        let identity = AgentSessionID(provider: .claude, profile: profile, nativeID: UUID().uuidString)
        switch surface {
        case "status": #expect(try await backend.status().authentication == .subscription)
        case "signIn": try await ProviderSignIn.run(backend: backend, onBrowserURL: { _ in })
        case "models": #expect(try await !backend.models().isEmpty)
        case "catalog": _ = try await backend.commandCatalog(directory: fixture.directory, projectID: nil)
        case "setup": _ = try await backend.setup(directory: fixture.directory, projectID: nil)
        case "mcpLogin": try await backend.signInMCP(name: "example", directory: fixture.directory, onBrowserURL: { _ in })
        case "sideQuestion":
            #expect(try await backend.sideQuestion(configuration: .init(directory: fixture.directory, resume: identity, model: "opus"), question: "Question") == "Side answer")
        default:
            let run = try await backend.start(.init(directory: fixture.directory, resume: surface == "fork" ? identity : nil,
                model: "opus", forkSession: surface == "fork", resumeSessionAt: surface == "fork" ? UUID().uuidString : nil))
            try await run.send(.init(text: "Hello"), willDeliver: {})
            _ = try await collectTurn(run)
            try await run.shutdown()
        }
        let launches = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        #expect(!launches.isEmpty && launches.allSatisfy { $0["home"]?.stringValue == expected })
        if surface == "fork" { #expect(launches.contains { $0["args"]?.arrayValue?.contains(.string("--fork-session")) == true }) }
    }

    @Test func nativeDiscoveryAndReadsAreScopedToEachHome() async throws {
        let first = try NativeHistoryFixture(), second = try NativeHistoryFixture()
        defer { first.remove(); second.remove() }
        try first.write(records: [first.record("user", text: "Account one")])
        try second.write(records: [second.record("user", text: "Account two")])
        let profile = UUID().uuidString
        let a = ClaudeBackend(environment: ["HOME": first.root.deletingLastPathComponent().path],
            overrides: ["CLAUDE_CONFIG_DIR": first.root.path])
        let b = ClaudeBackend(environment: [:], profile: profile, overrides: ["CLAUDE_CONFIG_DIR": second.root.path])
        let listA = try await (a as any AgentBackend).nativeSessions(folder: nil, cursor: nil, archived: false)
        let listB = try await (b as any AgentBackend).nativeSessions(folder: nil, cursor: nil, archived: false)
        #expect(listA.items.count == 1 && listB.items.count == 1)
        #expect(listA.items.first?.id.nativeID == listB.items.first?.id.nativeID)
        #expect(listA.items.first?.id.profile == "default" && listB.items.first?.id.profile == profile)
        let nativeA = try #require(listA.items.first?.id), nativeB = try #require(listB.items.first?.id)
        let historyA = try await a.readHistory(session: nativeA, cursor: nil)
        let historyB = try await b.readHistory(session: nativeB, cursor: nil)
        #expect(historyA.items.contains { if case .message(_, _, "Account one") = $0.kind { true } else { false } })
        #expect(historyB.items.contains { if case .message(_, _, "Account two") = $0.kind { true } else { false } })
        await #expect(throws: AgentFailure.invalidRequest) { try await b.readHistory(session: nativeA, cursor: nil) }
    }
}
