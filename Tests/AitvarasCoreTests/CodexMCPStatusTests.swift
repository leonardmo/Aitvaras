import Foundation
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct CodexMCPStatusTests {
    @Test func paginatedStatusOverlaysConcurrentThreadlessStartupUpdates() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
r=read(); assert r['method']=='mcpServerStatus/list' and r['params']=={'limit':100}
emit({'id':r['id'],'result':{'data':[{'name':'echo','status':'pending','authStatus':'unsupported'}],'nextCursor':'next'}})
r=read(); assert r['params']=={'limit':100,'cursor':'next'}
emit({'method':'mcpServer/startupStatus/updated','params':{'name':'echo','status':'ready'}})
emit({'id':r['id'],'result':{'data':[{'name':'docs','authStatus':'notLoggedIn'}],'nextCursor':None}})
r=read(); assert r['method']=='mcpServerStatus/list'
emit({'id':r['id'],'result':{'data':[{'name':'echo','authStatus':'unsupported'},{'name':'docs','authStatus':'notLoggedIn'}],'nextCursor':None}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let snapshot = try await backend.setup(directory: fixture.directory, projectID: nil)
        #expect(snapshot.provider == .codex)
        #expect(snapshot.servers.map(\.name) == ["docs", "echo"])
        #expect(snapshot.servers.map(\.status) == [.needsAuth, .connected])
        #expect(snapshot.servers.allSatisfy { $0.source == "provider" })
        #expect(snapshot.servers.last?.authentication == "unsupported")
        // list reports authentication, while startup notifications report
        // connectivity. A refresh must preserve that known connectivity.
        let refreshed = try await backend.setup(directory: fixture.directory, projectID: nil)
        #expect(refreshed.servers.map(\.status) == [.needsAuth, .connected])
        try fixture.assertComplete(); try await backend.shutdown()
        #expect(await !backend.availableSetup.serversAvailable)
    }

    @Test func startupNotificationsReachExistingRunsWithoutThreadRouting() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
start_thread()
r=read(); assert r['method']=='turn/start'
emit({'id':r['id'],'result':{'turn':{'id':'turn-example'}}})
emit({'method':'mcpServer/startupStatus/updated','params':{'name':'echo','status':'failed','error':'never-forward'}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-example','status':'completed'}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        try await run.send(.init(text: "Example"), willDeliver: {})
        let events = try await collectTurn(run)
        let snapshot = events.compactMap { if case .setupReported(let value) = $0.kind { value } else { nil } }.last
        #expect(snapshot?.servers.first?.status == .failed)
        #expect(!String(describing: events).contains("never-forward"))
        try await run.shutdown(); try await backend.shutdown()
    }

    @Test(arguments: ["repeated-cursor", "malformed", "unsupported"])
    func badOrUnsupportedStatusDoesNotPublishPartialDataOrBreakOtherReads(scenario: String) async throws {
        let body: String
        switch scenario {
        case "repeated-cursor": body = "emit({'id':r['id'],'result':{'data':[],'nextCursor':'same'}})\nr=read()\nemit({'id':r['id'],'result':{'data':[],'nextCursor':'same'}})"
        case "unsupported": body = "emit({'id':r['id'],'error':{'code':-32601,'message':'unsupported'}})"
        default: body = "emit({'id':r['id'],'result':{'data':[{'status':'connected'}]}})"
        }
        let fixture = try BackendExecutableFixture(script: "codex_init()\nr=read()\n" + body + "\nr=read(); assert r['method']=='account/read'\naccount(r)\ndone()")
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        await #expect(throws: (any Error).self) { try await backend.setup(directory: fixture.directory, projectID: nil) }
        #expect(await !backend.availableSetup.serversAvailable)
        #expect(try await backend.status().authentication == .subscription)
        try fixture.assertComplete(); try await backend.shutdown()
    }
}
