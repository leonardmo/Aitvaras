import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

/// Issue #23: real Claude tool_result frames carry their own `uuid`. A turn with
/// two or more tool calls must complete instead of being torn down as `.unknown`.
@Suite(.timeLimit(.minutes(2)))
struct AgentMultiToolTurnTests {
    static func script(tools: Int, hooks: Bool) -> String {
        var lines = [
            "claude_init()",
            "read()",
            "emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'multi-tool-session'})",
        ]
        for index in 0..<tools {
            let tool = "tool-\(index)"
            lines.append("emit({'type':'assistant','uuid':'assistant-uuid-\(index)','message':{'id':'msg-\(index)','role':'assistant','content':[{'type':'tool_use','id':'\(tool)','name':'Bash','input':{'command':'echo \(index)'}}]}})")
            if hooks {
                for hook in ["a", "b"] {
                    let id = "hook-\(index)-\(hook)"
                    lines.append("emit({'type':'system','subtype':'hook_started','hook_id':'\(id)','hook_name':'PreToolUse:Bash','hook_event':'PreToolUse'})")
                    lines.append("emit({'type':'system','subtype':'hook_response','hook_id':'\(id)','hook_name':'PreToolUse:Bash','hook_event':'PreToolUse','exit_code':0,'outcome':'success'})")
                }
            }
            lines.append("emit({'type':'user','uuid':'result-uuid-\(index)','message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'\(tool)','is_error':False,'content':'out \(index)'}]}})")
        }
        lines.append("emit({'type':'assistant','uuid':'final-uuid','message':{'id':'msg-final','role':'assistant','content':[{'type':'text','text':'all done'}]}})")
        lines.append("emit({'type':'result','uuid':'result-final','is_error':False})")
        lines.append("done()")
        return lines.joined(separator: "\n")
    }

    @Test(arguments: [(2, false), (2, true), (3, false), (3, true)])
    func claudeTurnWithSeveralToolCallsCompletes(tools: Int, hooks: Bool) async throws {
        let fixture = try BackendExecutableFixture(script: Self.script(tools: tools, hooks: hooks))
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        let input = AgentInput(text: "run some commands")
        try await manager.send(chatID: chat, provider: .claude, input: input)
        try await waitAgentCondition {
            let state = try stores.agentTurn(id: input.id)?.state
            return state != nil && state != .running
        }
        #expect(try stores.agentTurn(id: input.id)?.state == .completed)
        let entries = try stores.agentEntries(chatID: chat)
        #expect(entries.filter { $0.kind == "assistant" }.map(\.text) == ["all done"])
        #expect(entries.filter { $0.kind == "tool" }.count == tools)
        // Tool results are not echoes of the user's message.
        let user = try #require(entries.first { $0.id == input.id })
        #expect(user.nativeMessageID?.hasPrefix("result-uuid") != true)
        #expect(!entries.contains { $0.kind == "user" && $0.id != input.id })
        if hooks {
            // Passing hooks fold into their tool row, in order, once each.
            #expect(!entries.contains { $0.kind == "hook" })
            for tool in entries.filter({ $0.kind == "tool" }) {
                let payload = tool.payloadJSON.flatMap(JSONValue.parse)
                #expect(payload?["hooks"]?.arrayValue?.count == 2)
            }
        }
        #expect(try await manager.state(chatID: chat).outcome == .completed)
        try fixture.assertComplete()
        try await manager.shutdown()
    }
}
