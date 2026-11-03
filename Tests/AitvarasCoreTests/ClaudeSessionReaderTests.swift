import Foundation
import Testing
import AitvarasCore
@testable import AitvarasConnectors

private let claudeFixtureID = "11111111-1111-4111-8111-111111111111"
private let claudeMessageID = "22222222-2222-4222-8222-222222222222"

private struct ClaudeFixtureEnvelope<Value: Encodable>: Encodable {
    let ok = true
    let result: Value
}

private func claudeEnvelope<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try encoder.encode(ClaudeFixtureEnvelope(result: value))
}

private func claudeFixtureSession() -> NativeSessionSummary {
    .init(provider: .claude, externalID: claudeFixtureID, title: "Synthetic session",
          directory: "/synthetic/project", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func claudeHistoryPreservesStableIDsAndChronologicalDirection() async throws {
    let page = NativeTranscriptPage(
        session: claudeFixtureSession(),
        messages: [.init(externalID: claudeMessageID, role: .user, text: "Synthetic message")],
        nextCursor: "50", coverage: "Text only", direction: .newer)
    let data = try claudeEnvelope(page)
    let reader = ClaudeSessionReader { input in
        let request = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
        #expect(request["operation"] as? String == "read")
        #expect(request["offset"] as? Int == 0)
        #expect(request["id"] as? String == claudeFixtureID)
        return data
    }
    let result = try await reader.readSession(id: claudeFixtureID, directory: nil, cursor: nil)
    #expect(result.messages.first?.externalID == claudeMessageID)
    #expect(result.direction == .newer)
    #expect(result.nextCursor == "50")
    #expect(result.session.archived == nil)
    #expect(result.session.parentExternalID == nil)
}

@Test func claudeHistoryListsMetadataWithoutInventingArchiveOrForkState() async throws {
    let data = try claudeEnvelope(NativeSessionPage(sessions: [claudeFixtureSession()], coverage: "Archive state unknown"))
    let reader = ClaudeSessionReader { _ in data }
    let result = try await reader.listSessions(cursor: nil, archived: false)
    #expect(result.sessions.count == 1)
    #expect(result.sessions[0].archived == nil)
    #expect(result.sessions[0].activity == "Unknown")
    await #expect(throws: ClaudeSessionReader.ReaderError.unsupportedArchive) {
        try await reader.listSessions(cursor: nil, archived: true)
    }
}

@Test func claudeHistoryRejectsInvalidAndOverflowingCursors() throws {
    for cursor in ["-1", "+50", "050", " 50", "50x", "1000001", "999999999999999999999999", ""] {
        #expect(throws: ClaudeSessionReader.ReaderError.invalidRequest) { try ClaudeSessionReader.offset(cursor) }
    }
    #expect(try ClaudeSessionReader.offset(nil) == 0)
    #expect(try ClaudeSessionReader.offset("1000000") == 1_000_000)
}

@Test func claudeHistoryRejectsMalformedUnknownAndOversizedResponses() throws {
    for value in ["not json", "{\"ok\":true}", "{\"ok\":true,\"result\":{}}", "{}\n{}"] {
        #expect(throws: ClaudeSessionReader.ReaderError.malformedData) {
            let _: NativeSessionPage = try ClaudeSessionReader.decode(Data(value.utf8))
        }
    }
    #expect(throws: ClaudeSessionReader.ReaderError.outputTooLarge) {
        let _: NativeSessionPage = try ClaudeSessionReader.decode(Data(repeating: 32, count: 900_001))
    }
    #expect(throws: ClaudeSessionReader.ReaderError.readFailed) {
        let _: NativeSessionPage = try ClaudeSessionReader.decode(Data(#"{"ok":false,"error":"private transcript content"}"#.utf8))
    }
}

@Test func claudeHistoryRejectsNonAdvancingAndDuplicatePages() async throws {
    let badPage = try claudeEnvelope(NativeSessionPage(sessions: [claudeFixtureSession()], nextCursor: "0", coverage: "Synthetic"))
    let reader = ClaudeSessionReader { _ in badPage }
    await #expect(throws: ClaudeSessionReader.ReaderError.malformedData) {
        try await reader.listSessions(cursor: nil, archived: false)
    }
    let duplicate = try claudeEnvelope(NativeSessionPage(sessions: [claudeFixtureSession(), claudeFixtureSession()], coverage: "Synthetic"))
    let duplicateReader = ClaudeSessionReader { _ in duplicate }
    await #expect(throws: ClaudeSessionReader.ReaderError.malformedData) {
        try await duplicateReader.listSessions(cursor: nil, archived: false)
    }
}

@Test func claudeHistoryCapabilityErrorsRemainSanitized() async {
    let reader = ClaudeSessionReader { _ in Data(#"{"ok":false,"error":"missingSDK"}"#.utf8) }
    #expect(await reader.capabilities().state == .missingSDK)
    let unknown = ClaudeSessionReader { _ in Data(#"{"ok":false,"error":"private file path and content"}"#.utf8) }
    let result = await unknown.capabilities()
    #expect(result.state == .unavailable)
    #expect(!result.detail.contains("private file path"))
}

@Test func claudeHistoryEnvironmentDoesNotPassAuthenticationOrNodeInjection() {
    let environment = ClaudeSessionReader.environment(node: "/synthetic/bin/node", home: "/synthetic/home")
    #expect(environment["HOME"] == "/synthetic/home")
    #expect(environment["PATH"]?.hasPrefix("/synthetic/bin:") == true)
    #expect(Set(environment.keys).isSubset(of: ["HOME", "PATH", "LANG", "NO_COLOR", "CLAUDE_CONFIG_DIR"]))
    for key in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "NODE_OPTIONS", "NPM_TOKEN"] {
        #expect(environment[key] == nil)
    }
}

@Test func claudeHistoryHelperUsesOnlyOfficialReadAPIsWithSyntheticFixtures() async throws {
    guard let node = ClaudeSessionReader.findExecutable("node") else { return }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let helper = root.appendingPathComponent("Sources/AitvarasConnectors/Resources/claude-history.mjs")
    let helperJSON = String(decoding: try JSONEncoder().encode(helper.absoluteString), as: UTF8.self)
    let script = """
    import assert from 'node:assert/strict';
    const { handleRequest, PAGE_SIZE, MAX_OFFSET } = await import(\(helperJSON));
    const id = '11111111-1111-4111-8111-111111111111';
    const messageID = i => `22222222-2222-4222-8222-${String(i).padStart(12, '0')}`;
    const info = { sessionId: id, summary: 'Synthetic title', lastModified: 1700000000000, cwd: '/synthetic/project' };
    const calls = [];
    const row = (i, content, type = 'assistant') => ({ type, uuid: messageID(i), session_id: id, message: { content }, parent_tool_use_id: null, parent_agent_id: null });
    const sdk = {
      listSessions: async options => { calls.push(['list', options]); return [info]; },
      getSessionInfo: async (id, options) => { calls.push(['info', options]); return info; },
      getSessionMessages: async (id, options) => { calls.push(['messages', options]); return [
        row(1, 'First synthetic user message', 'user'),
        row(2, [{ type: 'thinking', thinking: 'omit this' }, { type: 'text', text: 'Visible answer' }, { type: 'tool_use', name: 'ignored' }]),
        row(3, [{ type: 'tool_result', content: 'omit this' }], 'user')
      ]; }
    };
    const page = await handleRequest({ operation: 'read', id }, sdk);
    assert.equal(page.direction, 'newer');
    assert.equal(page.messages.length, 2);
    assert.equal(page.messages[0].role, 'user');
    assert.equal(page.messages[1].text, 'Visible answer');
    assert.equal(page.messages[1].externalID, messageID(2));
    assert.match(page.coverage, /1 non-text/);
    assert.deepEqual(calls[1][1], { limit: PAGE_SIZE, offset: 0, includeSystemMessages: false });
    const list = await handleRequest({ operation: 'list', offset: 50 }, sdk);
    assert.equal(list.sessions[0].archived, null);
    assert.equal(list.sessions[0].parentExternalID, null);
    assert.deepEqual(calls.at(-1), ['list', { limit: PAGE_SIZE, offset: 50 }]);
    await assert.rejects(handleRequest({ operation: 'list', archived: true }, sdk), { code: 'unsupportedArchive' });
    await assert.rejects(handleRequest({ operation: 'list', offset: MAX_OFFSET + 1 }, sdk), { code: 'invalidRequest' });
    await assert.rejects(handleRequest({ operation: 'capabilities' }, sdk, '0.0.0'), { code: 'unsupported' });
    await assert.rejects(handleRequest({ operation: 'capabilities' }, {}), { code: 'unsupported' });
    sdk.listSessions = async () => Array(PAGE_SIZE).fill(info);
    await assert.rejects(handleRequest({ operation: 'list', offset: MAX_OFFSET }, sdk), { code: 'pageOverflow' });
    sdk.getSessionMessages = async () => [row(1, 'one'), row(1, 'duplicate')];
    await assert.rejects(handleRequest({ operation: 'read', id }, sdk), { code: 'malformedData' });
    sdk.getSessionInfo = async () => undefined;
    await assert.rejects(handleRequest({ operation: 'read', id }, sdk), { code: 'notFound' });
    console.log('synthetic-fixtures-passed');
    """
    let result = try await ProcessRunner.run(executable: node, arguments: ["--input-type=module"], currentDirectory: nil,
                                            timeout: 10, environment: ClaudeSessionReader.environment(node: node), standardInput: Data(script.utf8))
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "synthetic-fixtures-passed")
}
