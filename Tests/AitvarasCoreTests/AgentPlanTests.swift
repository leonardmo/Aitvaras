import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

@Suite struct AgentPlanTests {
    @Test(arguments: [AgentProvider.claude, .codex], ["approve", "fast", "reject", "fail", "stop"])
    func planReviewPreservesModeUntilAcknowledged(provider: AgentProvider, action: String) async throws {
        let script = provider == .claude ? claudePlanScript(action) : codexPlanScript(action)
        let fixture = try BackendExecutableFixture(script: script)
        defer { fixture.remove() }
        let backend: any AgentBackend = provider == .claude
            ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
            : CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let stores = try inMemoryStores()
        let (chat, saved) = try agentStoreChat(stores, provider: provider, cwd: fixture.directory.path)
        var session = saved; session.mode = .plan
        try stores.saveAgentSession(session)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        try await manager.send(chatID: chat.id, provider: provider, input: .init(text: "Plan an example change"))
        try await planWait { try await manager.state(chatID: chat.id).pendingCards.count == 1 }
        let request = try #require(try await manager.state(chatID: chat.id).pendingCards.first)
        #expect(request.kind == .plan("# Example plan\n\n- Add an example file."))
        #expect(try stores.agentSession(chatID: chat.id, provider: provider)?.mode == .plan)
        #expect(try await manager.state(chatID: chat.id).isRunning)
        let stale = AgentRequest(id: request.id, scope: .init(runID: UUID()), kind: request.kind)
        await #expect(throws: AgentFailure.invalidRequest) {
            try await manager.respond(chatID: chat.id, to: stale, with: .allow(updatedInput: nil))
        }
        if action == "stop" {
            try await manager.stop(chatID: chat.id)
        } else if action == "fail", provider == .codex {
            await #expect(throws: (any Error).self) {
                try await manager.respond(chatID: chat.id, to: request, with: .allow(updatedInput: nil))
            }
        } else {
            try await manager.respond(chatID: chat.id, to: request,
                                      with: action == "reject" ? .deny : .allow(updatedInput: nil))
        }
        try await planWait { try await !manager.state(chatID: chat.id).isRunning }
        let final = try await manager.state(chatID: chat.id)
        #expect(final.pendingCards.isEmpty)
        if provider == .codex {
            #expect(try stores.agentEntries(chatID: chat.id).contains { $0.nativeMessageID == AgentSessionID(provider: .codex, profile: "default", nativeID: "thread-test").canonicalMessageID("plan-item", turnID: "planning") && $0.text.hasPrefix("# Example plan") })
        }
        if action == "approve" || action == "fast" {
            try await planWait { try stores.agentSession(chatID: chat.id, provider: provider)?.mode == .ask }
            #expect(try await manager.state(chatID: chat.id).acknowledgedMode == .ask)
        } else { #expect(try stores.agentSession(chatID: chat.id, provider: provider)?.mode == .plan) }
        if action == "stop" { #expect(final.outcome == .interrupted) }
        if action == "fail", provider == .codex {
            await #expect(throws: AgentSessionManagerError.staleRun) {
                try await manager.respond(chatID: chat.id, to: request, with: .allow(updatedInput: nil))
            }
        } else {
            await #expect(throws: AgentFailure.invalidRequest) {
                try await manager.respond(chatID: chat.id, to: request, with: .allow(updatedInput: nil))
            }
        }
        if action != "stop" || provider == .claude {
            try await planWait { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
            try fixture.assertComplete()
        }
        try await manager.shutdown()
        if let backend = backend as? CodexBackend { try await backend.shutdown() }
    }

    @Test func recordingUsesNativeExitPlanAcknowledgement() async throws {
        let fixture = try BackendExecutableFixture(provider: "claude", name: "plan-mode")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "haiku", mode: .plan))
        try await run.send(.init(text: try fixture.prompt(provider: "claude", name: "plan-mode")), willDeliver: {})
        let events = try await collectTurn(run)
        let approval = try #require(events.firstIndex { if case .request(let r) = $0.kind, case .plan = r.kind { true } else { false } })
        let acknowledgement = try #require(events.firstIndex { $0.kind == .modeChanged(.ask) })
        #expect(acknowledgement > approval)
        #expect(!events[..<approval].contains { $0.kind == .modeChanged(.ask) })
        try await planWait { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete(); try await run.shutdown()
    }

    @Test func failedExplicitModeChangeEmitsNoAcknowledgement() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
r=read()
assert r['request']['subtype']=='set_permission_mode'
emit({'type':'control_response','response':{'subtype':'error','request_id':r['request_id'],'error':'rejected'}})
read()
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test", mode: .plan))
        await #expect(throws: (any Error).self) { try await run.setMode(.ask) }
        try await run.send(.init(text: "Still planning"), willDeliver: {})
        let events = try await collectTurn(run)
        #expect(!events.contains { if case .modeChanged = $0.kind { true } else { false } })
        try await run.shutdown()
    }

    @Test func unrelatedHookCannotAcknowledgeApprovedPlan() {
        var state = AgentModeState(.plan)
        let request = AgentRequest(id: .string("plan"), scope: .init(runID: UUID(), itemID: "plan-item"), kind: .plan("Example"))
        state.approve(request)
        let unrelated = state.acknowledgePlan(itemID: "other-item")
        #expect(!unrelated)
        #expect(state.mode == .plan)
        state.cancel()
        let cancelled = state.acknowledgePlan(itemID: "plan-item")
        #expect(!cancelled)
        state.approve(request)
        let acknowledged = state.acknowledgePlan(itemID: "plan-item")
        #expect(acknowledged)
        #expect(state.mode == .ask)
    }
}

private func claudePlanScript(_ action: String) -> String {
    let ending: String
    switch action {
    case "stop": ending = #"""
assert r['request']['subtype']=='interrupt'
emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}})
emit({'type':'result','is_error':True})
"""#
    case "reject": ending = "assert r['response']['response']['behavior']=='deny'\nemit({'type':'result','is_error':False})"
    case "fail": ending = "assert r['response']['response']['behavior']=='allow'\nemit({'type':'result','is_error':True})"
    default: ending = #"""
assert r['response']['response']['behavior']=='allow'
emit({'type':'control_request','request_id':'post','request':{'subtype':'hook_callback','callback_id':'post','tool_use_id':'plan-item','input':{'hook_event_name':'PostToolUse','tool_name':'ExitPlanMode','tool_input':{},'tool_response':{},'permission_mode':'default'}}})
assert read()['response']['response']['continue'] is True
emit({'type':'result','is_error':False})
"""#
    }
    return #"""
claude_init()
read()
emit({'type':'control_request','request_id':'plan','request':{'subtype':'can_use_tool','tool_name':'ExitPlanMode','tool_use_id':'plan-item','input':{'plan':'# Example plan\n\n- Add an example file.'}}})
r=read()
"""# + "\n" + ending + "\ndone()"
}

private func codexPlanScript(_ action: String) -> String {
    var script = #"""
codex_init()
start_thread()
r=read()
assert r['method']=='turn/start'
assert r['params']['sandboxPolicy']=={'type':'readOnly'}
assert r['params']['input'][0]['text']=='Plan an example change'
emit({'id':r['id'],'result':{'turn':{'id':'planning'}}})
emit({'method':'turn/plan/updated','params':{'threadId':'thread-test','turnId':'planning','plan':[{'step':'Informational only','status':'pending'}]}})
emit({'method':'item/plan/delta','params':{'threadId':'thread-test','turnId':'planning','itemId':'plan-item','delta':'Preview is not authoritative'}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'planning','status':'completed','items':[{'type':'plan','id':'plan-item','text':'# Example plan\n\n- Add an example file.'}]}}})
"""#
    if action == "approve" || action == "fast" || action == "fail" {
        script += #"""

r=read()
assert r['method']=='turn/start'
assert r['params']['sandboxPolicy']=={'type':'workspaceWrite'}
assert r['params']['approvalPolicy']=='untrusted'
assert r['params']['input'][0]['text']=='Implement the approved plan.'
"""#
        if action == "fast" {
            script += #"""

emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'execution','status':'completed','items':[]}}})
emit({'id':r['id'],'result':{'turn':{'id':'execution'}}})
"""#
        } else {
            script += action == "fail" ? "\nemit({'id':r['id'],'error':{'code':-32600,'message':'rejected'}})" : #"""

emit({'id':r['id'],'result':{'turn':{'id':'execution'}}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'execution','status':'completed','items':[]}}})
"""#
        }
    }
    return script + "\ndone()"
}

func planWait(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<300 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AgentFailure.offline
}
