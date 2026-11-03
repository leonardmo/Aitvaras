import Foundation
import Testing
@testable import AitvarasConnectors
import AitvarasCore

struct CodexSharedRuntimeEndpointTests {
    @Test func acceptsOnlyExplicitLiteralLoopback() throws {
        for endpoint in ["ws://127.0.0.1:54321", "ws://[::1]:54321/synthetic", "ws://127.0.0.1:80/"] {
            _ = try CodexSharedRuntimeClient.validateEndpoint(endpoint)
        }
        for endpoint in ["ws://localhost:54321", "ws://127.1:54321", "ws://2130706433:54321",
                         "ws://0x7f000001:54321", "ws://127.0.0.2:54321", "ws://[::ffff:127.0.0.1]:54321",
                         "ws://192.0.2.1:54321", "wss://127.0.0.1:54321", "ws://127.0.0.1",
                         "ws://user:synthetic@127.0.0.1:54321", "ws://127.0.0.1:54321?synthetic",
                         "ws://127.0.0.1:54321#synthetic", "ws://127.0.0.1:54321?", "ws://127.0.0.1:54321#",
                         "ws://127.0.0.1:0", "ws://127.0.0.1:65536", "ws://127.0.0.1:05432",
                         "ws://127.0.0.1:54321/%2f", "ws://127.0.0.1:54321/\\synthetic", "ws://127.0.0.1:54321/\n"] {
            #expect(throws: CodexSharedRuntimeError.invalidEndpoint) {
                _ = try CodexSharedRuntimeClient.validateEndpoint(endpoint)
            }
        }
    }
}

/// Synthetic helper processes only; none start Codex or connect to any listener.
@Suite(.enabled(if: CodexSessionReader.findNode() != nil && !AitvarasPaths.externalIntegrationsDisabled))
struct CodexSharedRuntimeClientTests {
    @Test func descriptorCannotClaimDesktopAttachment() async throws {
        let fixture = try Fixture(body: "send({result:result}); process.exit(0);")
        defer { fixture.remove() }
        let descriptor = try await fixture.client.probe(endpoint: "ws://127.0.0.1:54321/synthetic")
        #expect(descriptor.connected && descriptor.projectListAvailable)
        #expect(descriptor.runtimeIdentity == "unknown")
        #expect(!descriptor.desktopAttachmentVerified && !descriptor.continuationSupported)
    }

    @Test func falseDesktopAttestationIsRejected() async throws {
        let fixture = try Fixture(body: "result.desktopAttachmentVerified=true; send({result}); process.exit(0);")
        defer { fixture.remove() }
        await #expect(throws: CodexSharedRuntimeError.malformed) {
            _ = try await fixture.client.probe(endpoint: "ws://127.0.0.1:54321")
        }
    }

    @Test func malformedErrorsNeverExposeServerText() async throws {
        let fixture = try Fixture(body: "process.stdout.write('SYNTHETIC_PRIVATE_ERROR'); process.exit(0);")
        defer { fixture.remove() }
        do { _ = try await fixture.client.probe(endpoint: "ws://127.0.0.1:54321"); Issue.record("Malformed output accepted") }
        catch {
            #expect(error is CodexSharedRuntimeError)
            #expect(!error.localizedDescription.contains("SYNTHETIC_PRIVATE_ERROR"))
        }
    }

    @Test func structuredFailureAndOutputLimit() async throws {
        let unsupported = try Fixture(body: "send({error:'unsupported'}); process.exit(1);")
        defer { unsupported.remove() }
        await #expect(throws: CodexSharedRuntimeError.unsupported) {
            _ = try await unsupported.client.probe(endpoint: "ws://127.0.0.1:54321")
        }
        let oversized = try Fixture(body: "process.stdout.write('x'.repeat(20000)); setInterval(()=>{},1000);")
        defer { oversized.remove() }
        await #expect(throws: CodexSharedRuntimeError.tooLarge) {
            _ = try await oversized.client.probe(endpoint: "ws://127.0.0.1:54321")
        }
    }

    @Test func unresponsiveHelperHasBoundedDeadline() async throws {
        let fixture = try Fixture(body: "process.on('SIGTERM',()=>{}); setInterval(()=>{},1000);", timeout: 0.1)
        defer { fixture.remove() }
        let start = ContinuousClock.now
        await #expect(throws: CodexSharedRuntimeError.timeout) {
            _ = try await fixture.client.probe(endpoint: "ws://127.0.0.1:54321")
        }
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func cancellationNeverWaitsForHelperExit() async throws {
        let fixture = try Fixture(body: "process.on('SIGTERM',()=>{}); setInterval(()=>{},1000);")
        defer { fixture.remove() }
        let task = Task { try await fixture.client.probe(endpoint: "ws://127.0.0.1:54321") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private struct Fixture {
        let directory: URL
        let client: CodexSharedRuntimeClient
        init(body: String, timeout: TimeInterval = 8) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("aitvaras-shared-probe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let helper = directory.appendingPathComponent("fixture.mjs")
            try """
            let input=''; for await(const chunk of process.stdin) input+=chunk;
            const request=JSON.parse(input);
            if(request.operation!=='probe'||Object.keys(request).length!==2) process.exit(2);
            if(Object.keys(process.env).some(key=>/^(HOME|CODEX_HOME|OPENAI_API_KEY|NODE_OPTIONS|HTTPS_PROXY)$/.test(key))) process.exit(3);
            const send=value=>process.stdout.write(JSON.stringify(value)+'\\n');
            const result={connected:true,transport:'explicitLoopbackWebSocket',projectListAvailable:true,
              runtimeIdentity:'unknown',desktopAttachmentVerified:false,continuationSupported:false};
            \(body)
            """.write(to: helper, atomically: true, encoding: .utf8)
            client = CodexSharedRuntimeClient(nodePath: CodexSessionReader.findNode(), helperPath: helper.path, timeout: timeout)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
