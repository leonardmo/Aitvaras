import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent
@testable import AitvarasConnectors

/// Subscription-consuming end-to-end checks. The ordinary test suite skips
/// these; run explicitly with `AITVARAS_RUN_LIVE_CLI_TESTS=1 swift test
/// --filter CLILiveIntegrationTests`.
@Suite(.serialized) struct CLILiveIntegrationTests {
    private static let enabled =
        ProcessInfo.processInfo.environment["AITVARAS_RUN_LIVE_CLI_TESTS"] == "1"

    @Test(.enabled(if: enabled), .timeLimit(.minutes(10)))
    func delegateConnectorRunsClaudeAndCodexInIsolatedWorkspaces() async throws {
        for kind in DelegateConnector.AgentKind.allCases {
            let selection: CloudModelSelection =
                kind == .claude ? .claude : .codex
            let connector = DelegateConnector(selectionOverride: selection)
            #expect(await connector.health() == .ready)
            let workspace = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "aitvaras-live-delegate-\(kind.rawValue)-\(UUID().uuidString)",
                    isDirectory: true)
            try FileManager.default.createDirectory(
                at: workspace, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: workspace) }

            let marker = "\(kind.rawValue.uppercased())_AITVARAS_LIVE_OK"
            let arguments: [String: Any] = [
                "workingDirectory": workspace.path,
                "prompt": """
                    Create marker.txt in the current directory containing exactly \
                    \(marker) followed by a newline. Do not access anything outside \
                    the current directory. Verify the file, then report completion.
                    """
            ]
            let data = try JSONSerialization.data(
                withJSONObject: arguments, options: [.sortedKeys])
            let result = try await connector.execute(
                toolName: "run_coding_task",
                argumentsJSON: String(decoding: data, as: UTF8.self))

            let saved = try String(
                contentsOf: workspace.appendingPathComponent("marker.txt"),
                encoding: .utf8)
            #expect(saved == marker + "\n")
            #expect(!result.isEmpty)
        }
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(10)))
    func nightlyConsolidationCompletesWithEachCLIProvider() async throws {
        for selection in [
            CLIBackgroundEngine.Selection.claude,
            CLIBackgroundEngine.Selection.codex
        ] {
            let stores = try inMemoryStores()
            let now = Date()
            try stores.record(ActivityEvent(
                kind: .conversationArchived,
                timestamp: now.addingTimeInterval(-60),
                connectorID: "memory",
                summary: "Chat archived: the fictional test user prefers tea during afternoon study breaks"))
            let localFallback = ScriptedEngine(
                identifier: "local-fallback",
                responses: [
                    #"{"digest":"Unexpected fallback.","operations":[],"insights":[],"questions":[]}"#
                ])
            let cli = CLIBackgroundEngine(selection: selection, stores: stores)
            let consolidator = Consolidator(
                router: EngineRouter(ranked: [localFallback]),
                stores: stores,
                preferredEngine: cli)

            let outcome = await consolidator.run(now: now)

            #expect(outcome.ran && !outcome.failed)
            #expect(!outcome.digest.isEmpty)
            #expect(await localFallback.callCount() == 0)
            let event = try #require(try stores.recentActivity().first {
                $0.kind == .consolidationRun
            })
            #expect(event.detailJSON?.contains(
                #""engine":"cli-\#(selection.rawValue)""#) == true)
            #expect(event.detailJSON?.contains(#""fallback":false"#) == true)
            let usage = try stores.recentCloudUsage()
            #expect(usage.count == 1)
            #expect(usage[0].provider == selection.rawValue)
            #expect(usage[0].feature == CloudAgentFeature.nightlyMemory.rawValue)
            #expect(usage[0].policyVersion == AitvarasCloudPolicy.version)
        }
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(10)))
    func connectorManifestCreationWorksWithEachCLIProvider() async throws {
        for selection in [
            CloudModelSelection.claude,
            CloudModelSelection.codex
        ] {
            let stores = try inMemoryStores()
            let draft = try await ManifestDrafter.draft(
                description: "Create a read-only connector for a fictional service with GET /v1/status at https://api.example.com.",
                docsURL: "",
                stores: stores,
                selection: selection)

            let manifest = try ConnectorManifest.decodeAndValidate(
                Data(draft.json.utf8))
            #expect(manifest.baseURL == "https://api.example.com")
            #expect(!manifest.tools.isEmpty)
            #expect(manifest.tools.allSatisfy { $0.risk == .read })
            #expect(draft.provider.rawValue == selection.rawValue)
            #expect(try stores.recentCloudUsage().first?.feature
                    == CloudAgentFeature.connectorDrafting.rawValue)
        }
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(10)))
    func routineReviewWorksWithEachCLIProviderWithoutChangingExecution() async throws {
        for selection in [
            CloudModelSelection.claude,
            CloudModelSelection.codex
        ] {
            let stores = try inMemoryStores()
            let step = CommandRoutineStep(
                connectorID: "fictional",
                toolName: "light_off",
                argumentsJSON: #"{"room":"study"}"#,
                risk: .reversibleWrite)
            let routine = try CommandRoutine(
                title: "Fictional lights",
                triggerKind: .phrase,
                phrases: ["fictional lights off"],
                steps: [step],
                status: .active,
                evidenceCount: 3,
                explanation: "Locally derived.",
                dedupeKey: "live-\(selection.rawValue)")
            try stores.saveCommandRoutine(routine)

            try await RoutineCloudReviewer(
                stores: stores, selection: selection).review([routine])

            let reviewed = try #require(try stores.commandRoutines().first)
            #expect(reviewed.reviewProvider == selection.rawValue)
            #expect(reviewed.steps == [step])
            #expect(reviewed.phrases == ["fictional lights off"])
            #expect(reviewed.statusValue == .active)
        }
    }
}
