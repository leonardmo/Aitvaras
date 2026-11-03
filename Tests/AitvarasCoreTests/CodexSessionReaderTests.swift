import AitvarasCore
import Foundation
import Testing
@testable import AitvarasConnectors

@Suite struct CodexSessionReaderTests {
    private var helper: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AitvarasConnectors/Resources/codex-history.mjs").path
    }

    private struct Fixture {
        let directory: URL
        let executable: String
        let log: URL
        let pid: URL
        init(node: String, mode: String = "normal") throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            executable = directory.appendingPathComponent("fake-codex").path
            log = directory.appendingPathComponent("requests.jsonl")
            pid = directory.appendingPathComponent("child.pid")
            let code = #"""
            import fs from 'node:fs';
            import readline from 'node:readline';
            const mode = MODE;
            const dir = new URL('.', import.meta.url);
            if (process.argv[2] === '--version') { console.log('codex-cli 1.2.3-test'); process.exit(0); }
            fs.writeFileSync(new URL('child.pid', dir), String(process.pid));
            if (mode === 'hang') process.on('SIGTERM', () => {});
            const thread = {id:'thread_1', name:mode === 'named' ? 'Native title' : null, preview:'NEVER USE THIS AS TITLE', cwd:'/synthetic/project',
              forkedFromId:mode === 'spawned' ? null : 'thread_parent', parentThreadId:mode === 'spawned' ? 'thread_spawner' : null,
              updatedAt:1700000000, status:{type:mode === 'active' ? 'active' : 'notLoaded'}};
            const project = {id:'project_1',name:'Synthetic native project',roots:[{path:'/synthetic/z-worktree'},{path:'/synthetic/a-secondary'}],
              createdAt:1700000000,updatedAt:1700000001,position:3,recencyAt:null,metadata:{fixture:'synthetic'}};
            const rl = readline.createInterface({input:process.stdin});
            rl.on('line', line => {
              const req = JSON.parse(line);
              fs.appendFileSync(new URL('requests.jsonl', dir), JSON.stringify(req) + '\n');
              if (!req.id || mode === 'hang') return;
              let result;
              if (req.method === 'initialize') result = {};
              else if (req.method === 'project/list' || req.method === 'project/read') {
                if (mode === 'projectUnsupported') { console.log(JSON.stringify({id:req.id,error:{code:-32601,message:'PRIVATE PROJECT ERROR'}})); return; }
                const value = structuredClone(project);
                if (mode === 'projectMalformed') value.roots[0].path = '../not-absolute';
                if (mode === 'projectMismatch' && req.method === 'project/read') value.id = 'project_other';
                if (mode === 'projectLarge') value.name = 'x'.repeat(5000);
                result = req.method === 'project/read' ? {project:value} : {data:mode === 'empty' ? [] : [value],nextCursor:req.params.cursor ? null:'project-page-2'};
                if (mode === 'projectLoop' && req.params.cursor) result.nextCursor = req.params.cursor;
                if (mode === 'projectOversized') result.data = Array.from({length:51},(_,i) => ({...value,id:'project_'+i}));
              }
              else if (req.method === 'thread/list') result = {data:mode === 'empty' ? [] : [thread],nextCursor:req.params.cursor ? null:'page-2'};
              else if (req.method === 'thread/read') result = {thread};
              else if (req.method === 'thread/turns/list') {
                if (mode === 'unsupported') { console.log(JSON.stringify({id:req.id,error:{code:-32601,message:'PRIVATE SERVER ERROR'}})); return; }
                if (mode === 'error') { console.error('PRIVATE STDERR'); console.log(JSON.stringify({id:req.id,error:{code:-32000,message:'PRIVATE SERVER ERROR'}})); return; }
                const items = req.params.cursor ? [{id:'a2',type:'agentMessage',text:'Second page'}] : [
                  {id:'u1',type:'userMessage',content:[{type:'text',text:'Synthetic question'},{type:'image',url:'https://example.invalid/image'}]},
                  {id:'tool1',type:'commandExecution',aggregatedOutput:'Not a message'},
                  {id:'a1',type:'agentMessage',text:'Synthetic answer'},
                  {id:'reason1',type:'reasoning',text:'Not a message'}];
                result = {data:[{id:'turn_1',items}],nextCursor:req.params.cursor ? null:'turn-page-2'};
                if (mode === 'malformed') result.data[0].items = null;
                if (mode === 'large') result.data[0].items[2].text = 'x'.repeat(950000);
              } else { process.exit(9); }
              console.log(JSON.stringify({id:req.id,result}));
            });
            if (mode === 'hang') setInterval(() => {}, 1000);
            """#
            let encodedMode = String(decoding: try JSONEncoder().encode(mode), as: UTF8.self)
            try ("#!\(node)\n" + code.replacingOccurrences(of: "MODE", with: encodedMode))
                .write(toFile: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
        }
        func clean() { try? FileManager.default.removeItem(at: directory) }
        func requests() throws -> [[String: Any]] {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
        }
    }

    @Test func missingRuntimesAreHonest() async {
        let noNode = CodexSessionReader(nodePath: nil, codexPath: nil, helperPath: helper)
        #expect(await noNode.capabilities().state == .missingRuntime)
        let noCLI = CodexSessionReader(nodePath: "/synthetic/node", codexPath: nil, helperPath: helper)
        #expect(await noCLI.capabilities().state == .missingSDK)
    }

    @Test func helperEnvironmentExcludesCodeInjectionAndCredentials() {
        let result = CodexSessionReader.environment(node: "/synthetic/bin/node", inherited: [
            "CODEX_HOME": "/synthetic/codex", "NODE_OPTIONS": "--require=private",
            "OPENAI_API_KEY": "synthetic-secret", "PATH": "/untrusted/bin", "HOME": "/untrusted/home",
            "HTTPS_PROXY": "https://example.invalid"
        ])
        #expect(Set(result.keys) == ["HOME", "PATH", "LANG", "NO_COLOR", "CODEX_HOME"])
        #expect(result["CODEX_HOME"] == "/synthetic/codex")
        #expect(result["PATH"] == "/synthetic/bin:/usr/bin:/bin")
        #expect(CodexSessionReader.environment(node: "/synthetic/node", inherited: ["CODEX_HOME": "../invalid"])["CODEX_HOME"] == nil)
    }

    @Test func projectNamespaceTracksCanonicalProfileHomeWithoutExposingIt() {
        let firstHome = URL(fileURLWithPath: "/synthetic/profile-a")
        let aliasHome = URL(fileURLWithPath: "/synthetic/other/../profile-a")
        let first = CodexSessionReader(nodePath: nil, codexPath: nil, helperPath: helper, codexHome: firstHome)
        let alias = CodexSessionReader(nodePath: nil, codexPath: nil, helperPath: helper, codexHome: aliasHome)
        let second = CodexSessionReader(nodePath: nil, codexPath: nil, helperPath: helper,
                                        codexHome: URL(fileURLWithPath: "/synthetic/profile-b"))
        #expect(first.profileNamespace == alias.profileNamespace)
        #expect(first.profileNamespace != second.profileNamespace)
        #expect(!first.profileNamespace.contains("/"))
        #expect(!first.profileNamespace.contains("synthetic"))
        let configured = CodexSessionReader(nodePath: nil, codexPath: nil, helperPath: helper,
                                            profileNamespace: "synthetic-profile")
        #expect(configured.profileNamespace == "synthetic-profile")
    }

    @Test func discoversOrderedNativeProjectsWithoutMutationOrCwdInference() async throws {
        guard let node = CodexSessionReader.findNode() else { return }
        let fixture = try Fixture(node: node)
        defer { fixture.clean() }
        let reader = CodexSessionReader(nodePath: node, codexPath: fixture.executable, helperPath: helper,
                                        profileNamespace: "synthetic-profile")
        let capability = await reader.projectCapabilities()
        #expect(capability.state == .ready)
        #expect(capability.version == "1.2.3-test")
        #expect(capability.verifiedMethods == ["project/list", "project/read"])
        #expect(capability.profileNamespace == "synthetic-profile")
        let first = try await reader.listProjects(cursor: nil)
        let project = try #require(first.projects.first)
        #expect(project.identity == NativeProjectIdentity(provider: .codex, profileNamespace: "synthetic-profile", externalID: "project_1"))
        #expect(project.roots.map(\.path) == ["/synthetic/z-worktree", "/synthetic/a-secondary"])
        #expect(project.position == 3)
        #expect(project.metadata == ["fixture": "synthetic"])
        #expect(project.createdAt == Date(timeIntervalSince1970: 1700000000))
        #expect(project.recencyAt == nil)
        let second = try await reader.listProjects(cursor: first.nextCursor)
        #expect(second.nextCursor == nil)
        let reread = try await reader.readProject(id: project.identity.externalID)
        #expect(reread == project)
        let otherProfile = CodexSessionReader(nodePath: node, codexPath: fixture.executable, helperPath: helper,
                                              profileNamespace: "synthetic-other-profile")
        await #expect(throws: CodexSessionReader.HistoryError.invalidRequest) {
            _ = try await otherProfile.listProjects(cursor: first.nextCursor)
        }
        await #expect(throws: CodexSessionReader.HistoryError.invalidRequest) {
            _ = try await reader.listSessions(cursor: first.nextCursor, archived: false)
        }
        let requests = try fixture.requests()
        let allowed: Set<String> = ["initialize", "initialized", "project/list", "project/read"]
        #expect(requests.allSatisfy { allowed.contains($0["method"] as? String ?? "") })
        for request in requests where request["method"] as? String == "project/list" {
            let params = request["params"] as? [String: Any]
            #expect(params?["sortKey"] as? String == "position")
            #expect(params?["sortDirection"] as? String == "asc")
            #expect((params?["limit"] as? Int ?? 0) <= 50)
            #expect(params?["cwd"] == nil)
        }
    }

    @Test func emptyProjectCapabilitiesDoNotClaimVerifiedReads() async throws {
        guard let node = CodexSessionReader.findNode() else { return }
        let fixture = try Fixture(node: node, mode: "empty")
        defer { fixture.clean() }
        let reader = CodexSessionReader(nodePath: node, codexPath: fixture.executable, helperPath: helper)
        let capability = await reader.projectCapabilities()
        #expect(capability.state == .ready)
        #expect(capability.verifiedMethods == ["project/list"])
        #expect(capability.detail.contains("reads are unverified"))
        #expect(try fixture.requests().allSatisfy { $0["method"] as? String != "project/read" })
    }

    @Test(arguments: ["projectUnsupported", "projectMalformed", "projectMismatch", "projectLarge", "projectOversized", "projectLoop"])
    func rejectsUnsafeProjectResponses(mode: String) async throws {
        guard let node = CodexSessionReader.findNode() else { return }
        let fixture = try Fixture(node: node, mode: mode)
        defer { fixture.clean() }
        let reader = CodexSessionReader(nodePath: node, codexPath: fixture.executable, helperPath: helper)
        let expected: CodexSessionReader.HistoryError = mode == "projectUnsupported" ? .unsupported : .malformed
        await #expect(throws: expected) {
            if mode == "projectMismatch" { _ = try await reader.readProject(id: "project_1") }
            else if mode == "projectLoop" {
                let first = try await reader.listProjects(cursor: nil)
                _ = try await reader.listProjects(cursor: first.nextCursor)
            } else { _ = try await reader.listProjects(cursor: nil) }
        }
    }

    @Test func rejectsMalformedInputBeforeLaunching() async throws {
        let reader = CodexSessionReader(nodePath: nil, codexPath: nil, helperPath: helper)
        await #expect(throws: CodexSessionReader.HistoryError.invalidRequest) {
            _ = try await reader.readSession(id: "../private", directory: nil, cursor: nil)
        }
        await #expect(throws: CodexSessionReader.HistoryError.invalidRequest) {
            _ = try await reader.readSession(id: "thread_1\n", directory: nil, cursor: nil)
        }
        await #expect(throws: CodexSessionReader.HistoryError.invalidRequest) {
            _ = try await reader.listSessions(cursor: "bad\ncursor", archived: false)
        }
        await #expect(throws: CodexSessionReader.HistoryError.invalidRequest) {
            _ = try await reader.readProject(id: "../private")
        }
        let invalidProfile = CodexSessionReader(nodePath: nil, codexPath: nil, helperPath: helper,
                                                profileNamespace: "not/a/namespace")
        await #expect(throws: CodexSessionReader.HistoryError.invalidRequest) {
            _ = try await invalidProfile.listProjects(cursor: nil)
        }
    }

    @Test func readsNamedMetadataAndTextOnlyPagesWithoutMutation() async throws {
        guard let node = CodexSessionReader.findNode() else { return }
        let fixture = try Fixture(node: node)
        defer { fixture.clean() }
        let reader = CodexSessionReader(nodePath: node, codexPath: fixture.executable, helperPath: helper)
        let capability = await reader.capabilities()
        #expect(capability.state == .ready)
        #expect(capability.version == "1.2.3-test")
        #expect(capability.detail.contains("Transcript support is unverified"))
        #expect(try fixture.requests().compactMap { $0["method"] as? String } == ["initialize", "initialized", "thread/list"])
        let sessions = try await reader.listSessions(cursor: nil, archived: true)
        #expect(sessions.sessions.first?.title == "Untitled Codex session")
        #expect(sessions.sessions.first?.parentExternalID == "thread_parent")
        #expect(sessions.sessions.first?.parentRelationship == .fork)
        #expect(sessions.sessions.first?.archived == true)
        #expect(sessions.sessions.first?.activity == "Unknown")
        #expect(sessions.sessions.first?.updatedAt == Date(timeIntervalSince1970: 1700000000))
        let nextSessions = try await reader.listSessions(cursor: sessions.nextCursor, archived: true)
        #expect(nextSessions.nextCursor == nil)
        await #expect(throws: CodexSessionReader.HistoryError.invalidRequest) {
            _ = try await reader.listSessions(cursor: sessions.nextCursor, archived: false)
        }
        let first = try await reader.readSession(id: "thread_1", directory: "/must/not/be/used", cursor: nil)
        #expect(first.direction == .newer)
        #expect(first.messages.map(\.externalID) == ["u1", "a1"])
        #expect(first.messages.map(\.role) == [.user, .assistant])
        #expect(first.coverage.contains("Partial transcript"))
        let second = try await reader.readSession(id: "thread_1", directory: nil, cursor: first.nextCursor)
        #expect(second.messages.map(\.externalID) == ["a2"])
        #expect(second.nextCursor == nil)
        await #expect(throws: CodexSessionReader.HistoryError.invalidRequest) {
            _ = try await reader.readSession(id: "thread_2", directory: nil, cursor: first.nextCursor)
        }
        let requests = try fixture.requests()
        let allowed: Set<String> = ["initialize", "initialized", "thread/list", "thread/read", "thread/turns/list"]
        #expect(requests.allSatisfy { allowed.contains($0["method"] as? String ?? "") })
        for request in requests where request["method"] as? String == "thread/turns/list" {
            let params = request["params"] as? [String: Any]
            #expect(params?["itemsView"] as? String == "full")
            #expect(params?["sortDirection"] as? String == "asc")
        }
        for request in requests where request["method"] as? String == "thread/read" {
            #expect((request["params"] as? [String: Any])?["includeTurns"] as? Bool == false)
        }
    }

    @Test func nativeTitleAndEmptyCapabilityCoverageAreHonest() async throws {
        guard let node = CodexSessionReader.findNode() else { return }
        let named = try Fixture(node: node, mode: "named")
        let empty = try Fixture(node: node, mode: "empty")
        defer { named.clean(); empty.clean() }
        let namedReader = CodexSessionReader(nodePath: node, codexPath: named.executable, helperPath: helper)
        let page = try await namedReader.listSessions(cursor: nil, archived: false)
        #expect(page.sessions.first?.title == "Native title")
        let emptyReader = CodexSessionReader(nodePath: node, codexPath: empty.executable, helperPath: helper)
        let capability = await emptyReader.capabilities()
        #expect(capability.state == .ready)
        #expect(capability.detail.contains("Transcript support is unverified"))
    }

    @Test func spawnedSubagentDoesNotBecomeAFork() async throws {
        guard let node = CodexSessionReader.findNode() else { return }
        let fixture = try Fixture(node: node, mode: "spawned")
        defer { fixture.clean() }
        let reader = CodexSessionReader(nodePath: node, codexPath: fixture.executable, helperPath: helper)
        let page = try await reader.listSessions(cursor: nil, archived: false)
        #expect(page.sessions.first?.parentExternalID == "thread_spawner")
        #expect(page.sessions.first?.parentRelationship == .spawn)
        let transcript = try await reader.readSession(id: "thread_1", directory: nil, cursor: nil)
        #expect(transcript.session.parentRelationship == .spawn)
    }

    @Test(arguments: ["active", "unsupported", "error", "malformed", "large"])
    func reportsActivityAndSafeErrors(mode: String) async throws {
        guard let node = CodexSessionReader.findNode() else { return }
        let fixture = try Fixture(node: node, mode: mode)
        defer { fixture.clean() }
        let reader = CodexSessionReader(nodePath: node, codexPath: fixture.executable, helperPath: helper)
        if mode == "active" {
            let page = try await reader.readSession(id: "thread_1", directory: nil, cursor: nil)
            #expect(page.session.activity == "Active")
        } else {
            do {
                _ = try await reader.readSession(id: "thread_1", directory: nil, cursor: nil)
                Issue.record("Expected a bounded, sanitized error")
            } catch let error as CodexSessionReader.HistoryError {
                let expected: CodexSessionReader.HistoryError = switch mode {
                case "unsupported": .unsupported
                case "malformed": .malformed
                case "large": .tooLarge
                default: .unavailable
                }
                #expect(error == expected)
                #expect(!error.localizedDescription.contains("PRIVATE"))
            }
        }
    }

    @Test func cancellationKillsAndReapsAppServerChild() async throws {
        guard let node = CodexSessionReader.findNode() else { return }
        let fixture = try Fixture(node: node, mode: "hang")
        defer { fixture.clean() }
        let reader = CodexSessionReader(nodePath: node, codexPath: fixture.executable, helperPath: helper)
        let task = Task { try await reader.listSessions(cursor: nil, archived: false) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: fixture.pid.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(Int32(String(contentsOf: fixture.pid, encoding: .utf8)))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func timeoutKillsAndReapsAppServerChild() async throws {
        guard let node = CodexSessionReader.findNode() else { return }
        let fixture = try Fixture(node: node, mode: "hang")
        defer { fixture.clean() }
        let reader = CodexSessionReader(nodePath: node, codexPath: fixture.executable, helperPath: helper, timeout: 0.5)
        await #expect(throws: CodexSessionReader.HistoryError.timeout) {
            _ = try await reader.listSessions(cursor: nil, archived: false)
        }
        let pid = try #require(Int32(String(contentsOf: fixture.pid, encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
