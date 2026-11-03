import Foundation
import Darwin
import Testing
@testable import AitvarasConnectors
import AitvarasCore

/// These launch only tiny generated Node fixtures, never the real Codex CLI.
@Suite(.enabled(if: CodexSessionReader.findNode() != nil && !AitvarasPaths.externalIntegrationsDisabled))
struct CodexInteractiveClientTests {
    private enum FixtureError: Error { case refused }

    @Test func statusUsesBoundedFramesAndSanitizedEnvironment() async throws {
        let fixture = try Fixture(body: """
        if (Object.keys(process.env).some(k => /^(HOME|CODEX_HOME|OPENAI_API_KEY|NODE_OPTIONS|HTTPS_PROXY)$/.test(k))) process.exit(3);
        send({event:'result',result:{authenticated:false,models:[],usageSummary:'Unavailable, not zero'}});
        process.exit(0);
        """)
        defer { fixture.remove() }
        let status = try await fixture.client.status()
        #expect(!status.authenticated && status.models.isEmpty)
        #expect(status.usageSummary == "Unavailable, not zero")
    }

    @Test func splitUTF8StreamsAndPreservesActualTerminalState() async throws {
        let fixture = try Fixture(body: """
        send({event:'threadCreated',id:'synthetic-owned'});
        process.stdin.once('data', () => {
          send({event:'turnStarted',id:'synthetic-turn'});
          const line=Buffer.from(JSON.stringify({event:'textDelta',text:'Synthetic 🐉 reply'})+'\\n');
          const split=line.indexOf(Buffer.from('🐉'))+1;
          process.stdout.write(line.subarray(0,split));
          setImmediate(() => {
            process.stdout.write(line.subarray(split));
            send({event:'completed',state:'interrupted',inputTokens:7,outputTokens:2});
            send({event:'result',result:null}); process.exit(0);
          });
        });
        """)
        defer { fixture.remove() }
        let recorder = Recorder()
        try await fixture.client.run(sessionID: nil, context: "Synthetic context", model: "synthetic-model", effort: nil,
            prompt: "Synthetic message") { event in await recorder.record(event) }
        #expect(await recorder.values == ["thread:synthetic-owned", "turn:synthetic-turn", "Synthetic 🐉 reply", "interrupted"])
    }

    @Test func failedBindingCallbackNeverAcknowledgesDelivery() async throws {
        let fixture = try Fixture(body: """
        send({event:'threadCreated',id:'synthetic-owned'});
        process.stdin.once('data', () => { fs.writeFileSync(path.join(request.profileDirectory,'unexpected-ack'),'bad'); process.exit(0); });
        """)
        defer { fixture.remove() }
        do {
            try await fixture.client.run(sessionID: nil, context: "Synthetic context", model: "synthetic-model", effort: nil,
                prompt: "Synthetic message") { _ in throw FixtureError.refused }
            Issue.record("Binding failure was ignored")
        } catch { #expect(error is FixtureError) }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("unexpected-ack").path))
    }

    @Test func promptIsReleasedOnlyAfterTheAppRecordsTheDeliveryAttempt() async throws {
        let fixture = try Fixture(body: """
        send({event:'threadCreated',id:'synthetic-owned'});
        process.stdin.once('data', () => {
          send({event:'deliveryAttempt',id:'delivery:synthetic-owned'});
          process.stdin.once('data', chunk => {
            fs.writeFileSync(path.join(request.profileDirectory,'released'), String(chunk));
            send({event:'turnStarted',id:'synthetic-turn'});
            send({event:'completed',state:'completed',inputTokens:1,outputTokens:1});
            send({event:'result',result:null}); process.exit(0);
          });
        });
        """)
        defer { fixture.remove() }
        let recorder = Recorder()
        try await fixture.client.run(sessionID: nil, context: "Synthetic context", model: "synthetic-model", effort: nil,
            prompt: "Synthetic message") { event in await recorder.record(event) }
        #expect(await recorder.values == ["thread:synthetic-owned", "delivery", "turn:synthetic-turn", "completed"])
        let released = try String(contentsOf: fixture.directory.appendingPathComponent("released"), encoding: .utf8)
        #expect(released.contains("ackDelivery") && released.contains("delivery:synthetic-owned"))
    }

    @Test func unrecordedDeliveryAttemptNeverReleasesThePrompt() async throws {
        let fixture = try Fixture(body: """
        send({event:'threadCreated',id:'synthetic-owned'});
        process.stdin.once('data', () => {
          send({event:'deliveryAttempt',id:'delivery:synthetic-owned'});
          process.stdin.once('data', () => { fs.writeFileSync(path.join(request.profileDirectory,'unexpected-release'),'bad'); process.exit(0); });
        });
        """)
        defer { fixture.remove() }
        do {
            try await fixture.client.run(sessionID: nil, context: "Synthetic context", model: "synthetic-model", effort: nil,
                prompt: "Synthetic message") { event in
                    if case .deliveryAttempt = event { throw FixtureError.refused }
                }
            Issue.record("A failed delivery record was ignored")
        } catch { #expect(error is FixtureError) }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("unexpected-release").path))
    }

    @Test func malformedNativeTextNeverBecomesAnErrorPreview() async throws {
        let fixture = try Fixture(body: "process.stdout.write('SYNTHETIC_PRIVATE_DIAGNOSTIC\\n'); process.exit(0);")
        defer { fixture.remove() }
        do { _ = try await fixture.client.status(); Issue.record("Malformed frame accepted") }
        catch {
            #expect(error is CodexInteractiveError)
            #expect(!error.localizedDescription.contains("SYNTHETIC_PRIVATE_DIAGNOSTIC"))
        }
    }

    @Test func scopedReaderReturnsOnlyApprovedTextAndEmitsMetadata() async throws {
        let fixture = try Fixture(body: """
        if (request.projectRoots.length !== 1) process.exit(3);
        send({event:'projectToolRequest',id:'project-1',tool:'aitvaras_project_read',arguments:{root:0,path:'note.txt'}});
        process.stdin.once('data', data => {
          const reply=JSON.parse(data.toString().trim());
          if (reply.command !== 'projectToolResult' || reply.text !== 'synthetic approved text' || !reply.success) process.exit(4);
          send({event:'contextUsage',usedTokens:42,limitTokens:200});
          send({event:'result',result:null}); process.exit(0);
        });
        """)
        defer { fixture.remove() }
        try "synthetic approved text".write(to: fixture.directory.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let recorder = Recorder()
        let canonical = realpath(fixture.directory.path, nil)!
        let approvedRoot = String(cString: canonical); free(canonical)
        try await fixture.client.run(sessionID: nil, context: "Synthetic", model: "synthetic", effort: nil,
            prompt: "Read", projectRoots: [approvedRoot]) { event in await recorder.record(event) }
        #expect(await recorder.values == ["access:aitvaras_project_read:project[0]/note.txt:23", "context:42:200"])
    }

    @Test func emptySnapshotRejectsToolRequest() async throws {
        let fixture = try Fixture(body: """
        send({event:'projectToolRequest',id:'project-1',tool:'aitvaras_project_read',arguments:{root:0,path:'note.txt'}});
        """)
        defer { fixture.remove() }
        do {
            try await fixture.client.run(sessionID: nil, context: "Synthetic", model: "synthetic", effort: nil, prompt: "Read") { _ in }
            Issue.record("Text-only turn accepted a file tool")
        } catch { #expect(error is CodexInteractiveError) }
    }

    @Test func usageWindowUsesUnixTimeAndRejectsInvalidPercent() throws {
        let value = try JSONDecoder().decode(CodexUsageWindow.self, from: Data(#"{"usedPercent":25,"durationMinutes":300,"resetsAt":2000000000}"#.utf8))
        #expect(value.resetsAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(value.durationMinutes == 300)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CodexUsageWindow.self, from: Data(#"{"usedPercent":101}"#.utf8)) }
    }

    private struct Fixture {
        let directory: URL
        let client: CodexInteractiveClient
        init(body: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("aitvaras-codex-fixture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let helper = directory.appendingPathComponent("fixture.mjs")
            let source = """
            import fs from 'node:fs'; import path from 'node:path';
            const send=value=>process.stdout.write(JSON.stringify(value)+'\\n');
            process.stdin.once('data', data=>{ const request=JSON.parse(data.toString().trim()); \(body) });
            """
            try source.write(to: helper, atomically: true, encoding: .utf8)
            client = CodexInteractiveClient(profileDirectory: directory, nodePath: CodexSessionReader.findNode(),
                codexPath: "/synthetic/never-executed-codex", helperPath: helper.path)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private actor Recorder {
        var values: [String] = []
        func record(_ event: CodexInteractiveEvent) {
            switch event {
            case .threadCreated(let id): values.append("thread:\(id)")
            case .deliveryAttempt: values.append("delivery")
            case .turnStarted(let id): values.append("turn:\(id)")
            case .textDelta(let text): values.append(text)
            case .completed(let state, _, _): values.append(state)
            case .projectFileAccess(let tool, let path, let bytes): values.append("access:\(tool):\(path):\(bytes)")
            case .contextUsage(let used, let limit): values.append("context:\(used ?? -1):\(limit ?? -1)")
            default: break
            }
        }
    }
}
