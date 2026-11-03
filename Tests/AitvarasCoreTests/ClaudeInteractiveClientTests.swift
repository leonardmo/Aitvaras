import AitvarasCore
import Darwin
import Foundation
import Testing
@testable import AitvarasConnectors

/// Only generated Node fixtures run here. No official CLI, auth or model call.
@Suite(.enabled(if: ClaudeSessionReader.findExecutable("node") != nil && !AitvarasPaths.externalIntegrationsDisabled))
struct ClaudeInteractiveClientTests {
    private enum FixtureError: Error { case refused }
    private static let session = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private static let delivery = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private static let response = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    @Test func statusHasNoInheritedAuthenticationEnvironment() async throws {
        let fixture = try Fixture(status: """
        if (Object.keys(process.env).some(k => /^(HOME|CLAUDE_CONFIG_DIR|CLAUDE_SECURESTORAGE_CONFIG_DIR|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|NODE_OPTIONS|HTTPS_PROXY)$/.test(k))) process.exit(3);
        send({event:'result',result:{authenticated:false,models:[],usageWindows:null,accountLabel:null,profileNamespace:'b'.repeat(64)}}); process.exit(0);
        """, run: "process.exit(9);")
        defer { fixture.remove() }
        let status = try await fixture.client.status()
        #expect(!status.authenticated && status.models.isEmpty && status.usageWindows == nil)
        #expect(status.profileNamespace == String(repeating: "b", count: 64))
    }

    @Test func durableBarriersAndSplitUTF8PreserveOfficialEvidence() async throws {
        let fixture = try Fixture(run: Self.barriers + """
        process.stdin.once('data', data => {
          const ack = JSON.parse(data.toString());
          if (ack.command !== 'ackDelivery' || request.expectedNamespace !== 'b'.repeat(64)) process.exit(5);
          send({event:'turnStarted',id:'\(Self.response)'});
          const line = Buffer.from(JSON.stringify({event:'textDelta',text:'Synthetic 🐉 reply'})+'\\n');
          const split = line.indexOf(Buffer.from('🐉')) + 1;
          process.stdout.write(line.subarray(0,split));
          setImmediate(() => { process.stdout.write(line.subarray(split));
            send({event:'completed',state:'completed',inputTokens:7,outputTokens:2}); send({event:'result'}); process.exit(0); });
        }); });
        """)
        defer { fixture.remove() }
        let recorder = Recorder()
        try await fixture.run { await recorder.record($0) }
        #expect(await recorder.values == ["session", "delivery", "provider", "Synthetic 🐉 reply", "completed"])
    }

    @Test func failedSessionPersistenceNeverAcknowledges() async throws {
        let fixture = try Fixture(run: """
        send({event:'sessionCreated',id:'\(Self.session)'});
        process.stdin.once('data', () => { fs.writeFileSync(path.join(request.profileDirectory,'unexpected-ack'),'bad'); process.exit(0); });
        """)
        defer { fixture.remove() }
        do { try await fixture.run { _ in throw FixtureError.refused }; Issue.record("Failed persistence was ignored") }
        catch { #expect(error is FixtureError) }
        #expect(!fixture.exists("unexpected-ack"))
    }

    @Test func failedDeliveryPersistenceNeverReleases() async throws {
        let fixture = try Fixture(run: Self.barriers + """
        process.stdin.once('data', () => { fs.writeFileSync(path.join(request.profileDirectory,'unexpected-release'),'bad'); process.exit(0); }); });
        """)
        defer { fixture.remove() }
        do {
            try await fixture.run { if case .deliveryAttempt = $0 { throw FixtureError.refused } }
            Issue.record("Failed delivery record was ignored")
        } catch { #expect(error is FixtureError) }
        #expect(!fixture.exists("unexpected-release"))
    }

    @Test func missingProviderAcknowledgementCannotComplete() async throws {
        let fixture = try Fixture(run: Self.barriers + """
        process.stdin.once('data', () => { send({event:'completed',state:'completed'}); send({event:'result'}); process.exit(0); }); });
        """)
        defer { fixture.remove() }
        let recorder = Recorder()
        do { try await fixture.run { await recorder.record($0) }; Issue.record("Fabricated completion accepted") }
        catch { #expect(error as? ClaudeInteractiveError == .interruptedUnknown) }
        #expect(await recorder.values == ["session", "delivery"])
    }

    @Test func disconnectAfterDeliveryIsUnknownWithoutReplay() async throws {
        let fixture = try Fixture(run: Self.barriers + """
        process.stdin.once('data', () => { fs.writeFileSync(path.join(request.profileDirectory,'deliveries'),'1'); process.exit(1); }); });
        """)
        defer { fixture.remove() }
        let recorder = Recorder()
        do { try await fixture.run { await recorder.record($0) }; Issue.record("Disconnected turn succeeded") }
        catch { #expect(error as? ClaudeInteractiveError == .interruptedUnknown) }
        #expect(await recorder.values == ["session", "delivery"])
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("deliveries"), encoding: .utf8) == "1")
    }

    @Test func malformedPrivateOutputIsSanitized() async throws {
        let fixture = try Fixture(status: "process.stdout.write('SYNTHETIC_PRIVATE_DIAGNOSTIC\\n'); process.exit(0);", run: "")
        defer { fixture.remove() }
        do { _ = try await fixture.client.status(); Issue.record("Malformed frame accepted") }
        catch { #expect(error as? ClaudeInteractiveError == .malformed); #expect(!error.localizedDescription.contains("SYNTHETIC_PRIVATE_DIAGNOSTIC")) }
    }

    @Test func oversizedJSONLineFailsClosed() async throws {
        let fixture = try Fixture(status: "process.stdout.write('x'.repeat(300000));", run: "")
        defer { fixture.remove() }
        do { _ = try await fixture.client.status(); Issue.record("Oversized line accepted") }
        catch { #expect(error as? ClaudeInteractiveError == .tooLarge) }
    }

    @Test func operationLeaseIsExclusiveAndReleasesWithoutDeletingStaleFiles() throws {
        let fixture = try Fixture(run: "")
        defer { fixture.remove() }
        let namespace = String(repeating: "b", count: 64)
        let lease = try ClaudeOperationLease(profileDirectory: fixture.directory, namespace: namespace)
        #expect(throws: ClaudeInteractiveError.busy) { try ClaudeOperationLease(profileDirectory: fixture.directory, namespace: namespace) }
        lease.release()
        let reacquired = try ClaudeOperationLease(profileDirectory: fixture.directory, namespace: namespace)
        reacquired.release()
        #expect(fixture.exists("claude-live/\(namespace)/operation.lock"))
    }

    @Test func modesUseDistinctOpaquePartitionsAndOfficialSubscriptionLogin() {
        let profile = URL(fileURLWithPath: "/tmp/synthetic-aitvaras-profile")
        let shared = ClaudeInteractiveClient.profileNamespace(accountMode: .shared, profileDirectory: profile)
        let separate = ClaudeInteractiveClient.profileNamespace(accountMode: .separate, profileDirectory: profile)
        #expect(shared != separate && shared.count == 64 && separate.count == 64)
        if let guidance = ClaudeInteractiveClient.loginGuidance(accountMode: .shared, profileDirectory: profile) {
            #expect(guidance.environment["CLAUDE_CONFIG_DIR"] == nil)
            #expect(guidance.arguments == ["auth", "login", "--claudeai"])
        }
        if let guidance = ClaudeInteractiveClient.loginGuidance(accountMode: .separate, profileDirectory: profile) {
            #expect(guidance.environment == ["CLAUDE_CONFIG_DIR": guidance.configDirectory])
        }
    }

    @Test func typedProviderAuthenticationFailureIsForwardedWithoutErrorProse() async throws {
        let fixture = try Fixture(run: Self.barriers + """
        process.stdin.once('data', () => {
          send({event:'turnStarted',id:'\(Self.response)'});
          send({event:'providerFailure',code:'authenticationRequired',id:'\(Self.response)'});
          send({event:'completed',state:'failed'}); send({event:'result'}); process.exit(0);
        }); });
        """)
        defer { fixture.remove() }
        let recorder = Recorder()
        try await fixture.run { await recorder.record($0) }
        #expect(await recorder.values == ["session", "delivery", "provider", "failure:authenticationRequired", "failed"])
    }

    @Test func historyFramesPreserveUUIDTextAndMillisecondDateWithoutTurnEvents() async throws {
        let fixture = try Fixture(run: """
        if(request.operation !== 'history') process.exit(4);
        send({event:'history',snapshot:{sessionID:request.sessionID,profileNamespace:request.expectedNamespace,messages:[],complete:true,observedAt:1900000000000}});
        send({event:'historyMessage',id:'\(Self.response)',role:'assistant',text:'Canonical ',append:false});
        send({event:'historyMessage',id:'\(Self.response)',role:'assistant',text:'🐉',append:true});
        send({event:'result'}); process.exit(0);
        """)
        defer { fixture.remove() }
        let snapshot = try await fixture.client.readOwnedSession(sessionID: Self.session,
            expectedProfileNamespace: String(repeating: "b", count: 64))
        #expect(snapshot.sessionID == Self.session && snapshot.complete)
        #expect(snapshot.observedAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(snapshot.messages == [.init(id: Self.response, role: "assistant", text: "Canonical 🐉")])
    }

    @Test func historyRejectsCrossAccountSnapshot() async throws {
        let fixture = try Fixture(run: """
        send({event:'history',snapshot:{sessionID:request.sessionID,profileNamespace:'c'.repeat(64),messages:[],complete:true,observedAt:1900000000000}});
        send({event:'result'}); process.exit(0);
        """)
        defer { fixture.remove() }
        do {
            _ = try await fixture.client.readOwnedSession(sessionID: Self.session,
                expectedProfileNamespace: String(repeating: "b", count: 64))
            Issue.record("Cross-account history accepted")
        } catch { #expect(error as? ClaudeInteractiveError == .malformed) }
    }

    private static var barriers: String { """
    send({event:'sessionCreated',id:'\(session)'});
    process.stdin.once('data', data => {
      if (JSON.parse(data.toString()).command !== 'ackSession') process.exit(4);
      send({event:'deliveryAttempt',id:'\(delivery)'});
    """ }
    private struct Fixture {
        let directory: URL
        let client: ClaudeInteractiveClient
        init(status: String? = nil, run: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("aitvaras-claude-fixture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let helper = directory.appendingPathComponent("fixture.mjs")
            let status = status ?? "send({event:'result',result:{authenticated:true,models:[{id:'synthetic-model',displayName:'Synthetic',efforts:[]}],usageWindows:null,accountLabel:'learner@example.invalid',profileNamespace:'b'.repeat(64)}}); process.exit(0);"
            let source = """
            import fs from 'node:fs'; import path from 'node:path';
            const send = value => process.stdout.write(JSON.stringify(value)+'\\n');
            process.stdin.once('data', data => { const request = JSON.parse(data.toString().trim());
              if(request.operation === 'status') { \(status) } else { \(run) }
            });
            """
            try source.write(to: helper, atomically: true, encoding: .utf8)
            client = ClaudeInteractiveClient(accountMode: .separate, profileDirectory: directory,
                nodePath: ClaudeSessionReader.findExecutable("node"), executablePath: "/synthetic/never-executed-claude", helperPath: helper.path)
        }
        func run(_ handler: @escaping ClaudeInteractiveClient.EventHandler) async throws {
            try await client.run(sessionID: nil, context: "Synthetic context", model: "synthetic-model", effort: nil,
                                 prompt: "Synthetic prompt", onEvent: handler)
        }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path) }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
    private actor Recorder {
        var values: [String] = []
        func record(_ event: ClaudeInteractiveEvent) {
            switch event {
            case .sessionCreated: values.append("session")
            case .deliveryAttempt: values.append("delivery")
            case .turnStarted: values.append("provider")
            case .textDelta(let text): values.append(text)
            case .completed(let state, _, _): values.append(state)
            case .providerFailure(let code, _): values.append("failure:" + code)
            default: break
            }
        }
    }
}
