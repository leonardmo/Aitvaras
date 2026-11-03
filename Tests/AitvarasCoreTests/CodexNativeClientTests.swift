import AitvarasCore
import Foundation
import Testing
@testable import AitvarasConnectors

struct CodexNativeProtocolTests {
    @Test func jsonRetainsNestedUnknownItemsAndOpaqueIDs() throws {
        let value: CodexJSONValue = ["item": ["type": "futureNativeItem", "id": "synthetic-item", "value": [true, 7, .null, "text"]], "requestID": 42]
        #expect(try JSONDecoder().decode(CodexJSONValue.self, from: value.encoded()) == value)
        #expect(value["item"]?["id"]?.stringValue == "synthetic-item")
        #expect(value["requestID"]?.intValue == 42)
        #expect(value["item"]?["value"]?.arrayValue?.first?.boolValue == true)
        #expect(Set([value, value]).count == 1)
    }
    @Test func effectiveConfigurationPreservesNativePermissions() throws {
        let raw: CodexJSONValue = ["thread": ["id": "synthetic-thread"], "model": "synthetic-model", "modelProvider": "synthetic",
            "cwd": "/synthetic/workspace", "approvalPolicy": "never", "approvalsReviewer": "user",
            "sandbox": ["type": "readOnly"], "runtimeWorkspaceRoots": ["/synthetic/workspace"],
            "activePermissionProfile": ["id": ":synthetic"]]
        let config = try CodexNativeClient.effectiveConfiguration(raw, expectedThreadID: "synthetic-thread")
        #expect(config.raw == raw); #expect(config.approvalPolicy == "never")
        #expect(config.sandbox["type"]?.stringValue == "readOnly")
        #expect(throws: CodexNativeError.malformed) { _ = try CodexNativeClient.effectiveConfiguration(raw, expectedThreadID: "other-thread") }
    }
}

@Suite(.enabled(if: CodexSessionReader.findNode() != nil && !AitvarasPaths.externalIntegrationsDisabled))
struct CodexNativeClientTests {
    @Test func persistentRequestsAndCompleteNativePagination() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let info = try await fixture.client.connect()
        #expect(!info.desktopAttachmentVerified && !info.runtimeIdentityKnown)
        let snapshot = try await fixture.client.canonicalSnapshot(threadID: "synthetic-thread")
        #expect(snapshot.complete && snapshot.turns.count == 2 && snapshot.items.count == 2)
        #expect(snapshot.turns.map(\.id) == ["synthetic-turn-1", "synthetic-turn-2"])
        #expect(snapshot.items.map(\.kind) == ["userMessage", "futureNativeItem"])
        #expect(snapshot.items[0].raw["item"]?["clientId"]?.stringValue == "synthetic-client-id")
        #expect(snapshot.items[1].raw["item"]?["opaque"] == ["preserve": true])
        #expect(snapshot.items[1].raw["startedAtMs"]?.intValue == 1234)
        #expect(snapshot.raw["futureMetadata"]?.stringValue == "preserved")
        let config = try await fixture.client.resume(threadID: snapshot.id)
        #expect(config.cwd == "/synthetic/workspace")
        await fixture.client.disconnect()
    }
    @Test func cursorCyclesAndDuplicateIDsNeverBecomeCompleteSnapshots() async throws {
        for scenario in ["cycle", "duplicate", "orphan"] {
            let fixture = try Fixture(scenario: scenario); defer { fixture.remove() }
            _ = try await fixture.client.connect()
            await #expect(throws: CodexNativeError.malformed) { _ = try await fixture.client.canonicalSnapshot(threadID: "synthetic-thread") }
            await fixture.client.disconnect()
        }
    }
    @Test func forbiddenMethodCannotReachHelper() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try await fixture.client.connect()
        for method in ["thread/shellCommand", "thread/delete", "thread/revert", "thread/injectItems", "config/value/write"] {
            await #expect(throws: CodexNativeError.invalidRequest) { _ = try await fixture.client.request(method: method) }
        }
        await fixture.client.disconnect()
    }
    @Test func cancellationAndFaultyHelperAreBounded() async throws {
        let fixture = try Fixture(scenario: "hang", timeout: .milliseconds(100)); defer { fixture.remove() }
        let start = ContinuousClock.now
        await #expect(throws: CodexNativeError.timeout) { _ = try await fixture.client.connect() }
        #expect(start.duration(to: .now) < .seconds(2))
        let canceled = try Fixture(scenario: "hang"); defer { canceled.remove() }
        let task = Task { try await canceled.client.connect() }
        try await Task.sleep(for: .milliseconds(50)); task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    @Test func falseDesktopAttestationAndOversizedWireAreRejected() async throws {
        for (scenario, expected) in [("attestation", CodexNativeError.malformed), ("oversized", .tooLarge)] {
            let fixture = try Fixture(scenario: scenario); defer { fixture.remove() }
            await #expect(throws: expected) { _ = try await fixture.client.connect() }
        }
    }
    private struct Fixture {
        let directory: URL
        let client: CodexNativeClient
        init(scenario: String = "normal", timeout: Duration = .seconds(2)) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("aitvaras-native-fixture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let helper = directory.appendingPathComponent("fixture.mjs")
            let source = """
            import {createInterface} from 'node:readline';
            const scenario='\(scenario)';
            const send=f=>process.stdout.write(JSON.stringify(f)+'\\n');
            const thread={id:'synthetic-thread',name:'Synthetic',projectId:'synthetic-project',cwd:'/synthetic/workspace',status:{type:'idle'},futureMetadata:'preserved'};
            const turn=(id)=>({id,status:'completed',items:[],itemsView:'notLoaded'});
            for await(const line of createInterface({input:process.stdin})) {
              const c=JSON.parse(line); let result;
              if(c.op==='connect') {
                if(scenario==='hang') {process.on('SIGTERM',()=>{});continue;}
                if(scenario==='oversized') {process.stdout.write('x'.repeat(5*1024*1024));continue;}
                result={transport:'explicitLoopbackWebSocket',runtimeIdentityKnown:false,desktopAttachmentVerified:scenario==='attestation',detail:'Synthetic connection'};
              } else if(c.op==='request') {
                const p=c.params;
                if(c.method==='thread/read') result={thread};
                else if(c.method==='thread/resume') result={thread,model:'synthetic-model',modelProvider:'synthetic',cwd:thread.cwd,approvalPolicy:'on-request',approvalsReviewer:'user',sandbox:{type:'workspaceWrite'},runtimeWorkspaceRoots:[thread.cwd]};
                else if(c.method==='thread/turns/list') {
                  const cursor=p.cursor;
                  result={data:[turn(cursor?(scenario==='duplicate'?'synthetic-turn-1':'synthetic-turn-2'):'synthetic-turn-1')],nextCursor:cursor?(scenario==='cycle'?'synthetic-cursor':null):'synthetic-cursor'};
                } else if(c.method==='thread/items/list') result={data:[
                  {turnId:'synthetic-turn-1',item:{id:'synthetic-item-1',type:'userMessage',clientId:'synthetic-client-id',content:[{type:'text',text:'Synthetic'}]}},
                  {turnId:scenario==='orphan'?'synthetic-orphan':'synthetic-turn-2',startedAtMs:1234,item:{id:'synthetic-item-2',type:'futureNativeItem',opaque:{preserve:true}}}
                ],nextCursor:null};
                else result={};
              } else result={};
              send({kind:'result',id:c.id,result});
            }
            """
            try source.write(to: helper, atomically: true, encoding: .utf8)
            client = CodexNativeClient(configuration: .init(transport: .loopbackWebSocket("ws://127.0.0.1:54321/synthetic"), profileNamespace: "synthetic-profile"),
                                       nodePath: CodexSessionReader.findNode(), codexPath: nil, helperPath: helper.path, timeout: timeout)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
