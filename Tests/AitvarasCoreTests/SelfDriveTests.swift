#if DEBUG
import Foundation
import Testing
import AitvarasCore

@Suite struct SelfDriveTests {
    @Test func parsesEveryActionAndUnicodeText() throws {
        let scenario = try SelfDriveScenario.parse(Data(#"""
        {"steps":[
          {"action":"press","identifier":"chat.new"},
          {"action":"type","text":"Hello 🐉\nsecond line"},
          {"action":"waitFor","text":"Hello","timeout":0.1},
          {"action":"waitFor","identifier":"chat.request.1.allow","absent":true,"timeout":0},
          {"action":"screenshot","name":"01-launch","delay":3},
          {"action":"dumpTree","name":"01-launch-tree"}
        ]}
        """#.utf8))
        #expect(scenario.steps.count == 6)
        #expect(scenario.steps[1].text == "Hello 🐉\nsecond line")
        #expect(scenario.steps[3].absent == true)
    }

    @Test(arguments: [
        #"{"steps":[{"action":"unknown"}]}"#,
        #"{"steps":[{"action":"press"}]}"#,
        #"{"steps":[{"action":"type"}]}"#,
        #"{"steps":[{"action":"waitFor","identifier":"x","text":"y"}]}"#,
        #"{"steps":[{"action":"waitFor","text":""}]}"#,
        #"{"steps":[{"action":"waitFor","text":"x","timeout":-1}]}"#,
        #"{"steps":[{"action":"press","identifier":"x","delay":301}]}"#,
        #"{"steps":[{"action":"screenshot","name":"../escape"}]}"#,
        #"{"steps":[{"action":"dumpTree","name":"/absolute"}]}"#,
        #"{"steps":[{"action":"dumpTree","name":".."}]}"#,
        "not json"
    ]) func rejectsMalformedScenarios(json: String) {
        #expect(throws: (any Error).self) { try SelfDriveScenario.parse(Data(json.utf8)) }
    }

    @MainActor @Test func failureContinuesAndCheckpointsRoundTrip() async throws {
        let scenario = try SelfDriveScenario.parse(Data(#"""
        {"steps":[{"action":"press","identifier":"missing"},
                  {"action":"type","text":"still runs"},
                  {"action":"screenshot","name":"after-failure"}]}
        """#.utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("results.json")
        var checkpoints: [Int] = []
        var actions: [SelfDriveStep.Action] = []
        let results = try await SelfDriveRecorder.run(scenario, perform: { step in
            actions.append(step.action)
            if step.action == .press { throw SelfDriveFailure("Identifier unavailable") }
            return "Observed success"
        }, checkpoint: { results in
            checkpoints.append(results.count)
            try JSONEncoder().encode(results).write(to: url, options: .atomic)
        })
        #expect(actions == [.press, .type, .screenshot])
        #expect(checkpoints == [0, 1, 2, 3])
        #expect(results.map(\.status) == ["failed", "passed", "passed"])
        let saved = try JSONDecoder().decode([SelfDriveResult].self, from: Data(contentsOf: url))
        #expect(saved.map(\.index) == [0, 1, 2])
        #expect(saved[0].reason == "Identifier unavailable")
        #expect(saved[2].action == "screenshot")
    }

    @MainActor @Test func checkpointFailureIsSurfaced() async throws {
        let scenario = try SelfDriveScenario.parse(Data(#"{"steps":[]}"#.utf8))
        await #expect(throws: SelfDriveFailure.self) {
            try await SelfDriveRecorder.run(scenario, perform: { _ in "unused" },
                                           checkpoint: { _ in throw SelfDriveFailure("Output unavailable") })
        }
    }

    @Test func checkedInScenariosParseAndKeepGoldenScreenshotNames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scenario = try SelfDriveScenario.parse(Data(contentsOf: root.appendingPathComponent("UITests/self-drive/golden-path.json")))
        let names = scenario.steps.filter { $0.action == .screenshot }.compactMap(\.name)
        #expect(names == ["01-launch", "02-chat-empty", "03-new-chat", "04-claude-selected",
                          "05-claude-streaming", "06-claude-replied", "07-codex-selected", "08-codex-replied",
                          "09-approval-card", "10-after-approval", "11-running", "12-stopped", "13-local-selected",
                          "14-menu-chat.model", "14-menu-chat.mode", "14-menu-chat.effort", "15-settings", "16-settings-providers"])
        _ = try SelfDriveScenario.parse(Data(contentsOf: root.appendingPathComponent("UITests/self-drive/probe.json")))
    }
}
#endif
