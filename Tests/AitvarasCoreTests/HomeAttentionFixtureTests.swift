import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent

/// `--seed-home-attention` must produce the card the self-drive scenario and the
/// manual checklist in TESTING.md rely on.
@Suite(.timeLimit(.minutes(2))) struct HomeAttentionFixtureTests {
    @Test func seedProducesTheDocumentedAttentionStateOnce() throws {
        let stores = try inMemoryStores()
        #expect(try HomeAttentionFixtures.seed(into: stores))
        #expect(try !HomeAttentionFixtures.seed(into: stores))

        let snapshot = try stores.activityAttentionSnapshot()
        let titles = snapshot.groups.map(\.latestRun.title)
        #expect(snapshot.groups.count == 5)
        #expect(Set(titles) == ["Index selected folders", "Download local model", "Nightly memory consolidation",
                                "Send queued external notification", "Archive conversation"])
        let indexing = try #require(snapshot.groups.first { $0.latestRun.title == "Index selected folders" })
        #expect(indexing.totalCount == 3)
        // The recovered capture summary stays in History but not in attention.
        #expect(!titles.contains("Summarize saved capture"))
        #expect(try stores.activityRuns().contains { $0.title == "Summarize saved capture" })
        // Dismiss all skips the unknown outcome.
        let unknown = try #require(snapshot.groups.first { $0.latestRun.state == .outcomeUnknown })
        #expect(!snapshot.bulkDismissibleRunIDs.contains(unknown.latestRun.id))

        let held = try stores.heldNotifications()
        #expect(held.map(\.title) == ["Library pickup ready", "Build finished"])
        #expect(try stores.pendingSuggestions().count == 1)
    }

    /// The self-drive scenario addresses seeded rows by identifier; keep it in
    /// step with the fixture so a changed key or ID fails here, not in the app.
    @Test func selfDriveScenarioNamesRowsTheFixtureProduces() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../UITests/self-drive/home-attention.json").standardized
        let scenario = try SelfDriveScenario.parse(Data(contentsOf: url))
        #expect(scenario.seed == [.homeAttention])
        let stores = try inMemoryStores()
        try HomeAttentionFixtures.seed(into: stores)
        let rows = Set(HomeAttentionCard(snapshot: try stores.homeAttentionSnapshot()).rows.map(\.accessibilityIdentifier))
        let named = Set(scenario.steps.compactMap(\.identifier).filter { $0.hasPrefix("home.attention.") }
            .map { id in [".open", ".dismiss", ".approve", ".reject"].reduce(id) { $0.hasSuffix($1) ? String($0.dropLast($1.count)) : $0 } }
            .filter { !["home.attention.card", "home.attention.more", "home.attention.undo", "home.attention.undoBar",
                        "home.attention.dismissAll", "home.attention.automaticWork"].contains($0) })
        #expect(!named.isEmpty)
        #expect(named.subtracting(rows).isEmpty, "Scenario names rows the fixture does not seed: \(named.subtracting(rows))")
        #expect(rows.contains("home.attention.automaticWork"))
    }

    @Test func seededArchiveFailureIsRetryableForItsConversation() async throws {
        let stores = try inMemoryStores()
        try HomeAttentionFixtures.seed(into: stores)
        let failed = try #require(try stores.activityAttentionSnapshot().groups
            .first { $0.latestRun.title == "Archive conversation" }).latestRun
        guard case .conversationArchive(let id, let key)? = ActivityRetryTarget(run: failed) else {
            Issue.record("Seeded archive failure has no retry target"); return
        }
        let engine = ScriptedEngine(responses: [#"{"summary": "Seminar planning.", "facts": []}"#])
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [engine]), stores: stores,
            reporter: ActivityReporter(stores: stores))
        #expect(try await archiver.retryStoredConversation(id: id, expectedJobKey: key, excluding: []) == .archived)
        #expect(try !stores.activityAttentionSnapshot().groups.contains { $0.latestRun.title == "Archive conversation" })
    }
}
