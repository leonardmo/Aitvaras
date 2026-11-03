import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent
@testable import AitvarasConnectors

@Suite struct CloudAgentTests {
    @Test func usageLedgerSummarizesMetadataWithoutPromptContent() throws {
        let stores = try inMemoryStores()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try stores.recordCloudUsage(CloudUsageRecord(
            timestamp: now.addingTimeInterval(-60),
            feature: CloudAgentFeature.nightlyMemory.rawValue,
            provider: "claude",
            durationMilliseconds: 1_500,
            inputCharacters: 4_000,
            inputTokens: 1_000,
            outputTokens: 100,
            reportedCostUSD: 0.01,
            succeeded: true,
            dataCategories: CloudAgentFeature.nightlyMemory.dataCategories,
            policyVersion: AitvarasCloudPolicy.version))
        try stores.recordCloudUsage(CloudUsageRecord(
            timestamp: now.addingTimeInterval(-30),
            feature: CloudAgentFeature.routineReview.rawValue,
            provider: "codex",
            durationMilliseconds: 900,
            inputCharacters: 2_000,
            inputTokens: 500,
            outputTokens: 50,
            succeeded: false,
            dataCategories: CloudAgentFeature.routineReview.dataCategories,
            policyVersion: AitvarasCloudPolicy.version,
            failureKind: "SyntheticFailure"))

        let summary = try stores.cloudUsageSummary(now: now, calendar: calendar)

        #expect(summary.callsToday == 2)
        #expect(summary.callsThisMonth == 2)
        #expect(summary.successfulCallsThisMonth == 1)
        #expect(summary.inputTokensThisMonth == 1_500)
        #expect(summary.outputTokensThisMonth == 150)
        #expect(summary.reportedCostUSDThisMonth == 0.01)
        #expect(summary.lastUse?.provider == "codex")
        let encoded = try JSONEncoder().encode(try stores.recentCloudUsage())
        let persisted = String(decoding: encoded, as: UTF8.self)
        #expect(!persisted.contains("secret prompt"))
        #expect(!persisted.contains("model response"))
        let breakdown = try stores.cloudUsageBreakdown(
            now: now, calendar: calendar)
        #expect(breakdown.count == 2)
        #expect(breakdown.first {
            $0.feature == CloudAgentFeature.nightlyMemory.rawValue
        }?.inputTokens == 1_000)
        #expect(try stores.recentCloudUsage(
            feature: CloudAgentFeature.routineReview.rawValue).count == 1)
    }

    @Test func cloudReviewCanChangePresentationButNotExecution() throws {
        let stores = try inMemoryStores()
        let step = CommandRoutineStep(
            connectorID: "lights",
            toolName: "turn_off",
            argumentsJSON: #"{"room":"fictional-study"}"#,
            risk: .reversibleWrite)
        let routine = try CommandRoutine(
            title: "Old title",
            triggerKind: .phrase,
            phrases: ["fictional lights off"],
            steps: [step],
            status: .active,
            evidenceCount: 3,
            explanation: "Local explanation.",
            dedupeKey: "synthetic-review")
        try stores.saveCommandRoutine(routine)

        try stores.applyCloudReview(
            to: routine.id,
            provider: "codex",
            title: "Study lights off",
            summary: "Runs the same locally observed light-off path.")
        let saved = try #require(try stores.commandRoutines().first {
            $0.id == routine.id
        })

        #expect(saved.title == "Study lights off")
        #expect(saved.reviewProvider == "codex")
        #expect(saved.reviewedAt != nil)
        #expect(saved.steps == [step])
        #expect(saved.phrases == ["fictional lights off"])
        #expect(saved.statusValue == .active)
    }

    @Test func routineReviewParserIsBoundToKnownCandidates() throws {
        let allowed = UUID()
        let valid = """
        {"reviews":[{"id":"\(allowed.uuidString)","title":"Useful title","summary":"A bounded factual explanation."}]}
        """
        let parsed = try RoutineCloudReviewer.parse(valid, allowedIDs: [allowed])
        #expect(parsed.count == 1)
        #expect(parsed[0].id == allowed)

        let unknown = UUID()
        let invalid = """
        {"reviews":[{"id":"\(unknown.uuidString)","title":"Invented","summary":"Unknown candidate."}]}
        """
        #expect(throws: (any Error).self) {
            try RoutineCloudReviewer.parse(invalid, allowedIDs: [allowed])
        }
    }

    @Test func cloudFeatureDisclosuresNameEveryTransferredCategory() {
        for feature in CloudAgentFeature.allCases {
            #expect(!feature.dataCategories.isEmpty)
            #expect(!feature.disclosure.isEmpty)
        }
        #expect(CloudAgentFeature.nightlyMemory.disclosure.contains(
            "conversation summaries"))
        #expect(CloudAgentFeature.connectorDrafting.disclosure.contains(
            "documentation"))
        #expect(CloudAgentFeature.routineReview.disclosure.contains(
            "tool names/arguments"))
    }

    @Test func nightlyShapeValidationRejectsIncompleteOrNonJSONResults() {
        let valid = """
        {"digest":"Done","operations":[],"insights":[],"questions":[]}
        """
        #expect(CLIBackgroundEngine.hasNightlyPlanShape(valid))
        #expect(CLIBackgroundEngine.hasNightlyPlanShape("```json\n\(valid)\n```"))
        #expect(!CLIBackgroundEngine.hasNightlyPlanShape(
            #"{"digest":"Missing arrays"}"#))
        #expect(!CLIBackgroundEngine.hasNightlyPlanShape("not json"))
    }

    @Test func providerSelectionsAreResolvedAgainForEveryCall() async throws {
        let box = SelectionBox(.local)
        let stores = try inMemoryStores()
        let nightly = CLIBackgroundEngine(
            stores: stores, selectionProvider: { box.get() })
        let reviewer = RoutineCloudReviewer(
            stores: stores, selectionProvider: { box.get() })

        #expect(await nightly.selectionForNextCall() == .local)
        #expect(await reviewer.selectionForNextReview() == .local)
        box.set(.codex)
        #expect(await nightly.selectionForNextCall() == .codex)
        #expect(await reviewer.selectionForNextReview() == .codex)
    }

    @Test func localModelMeterRecordsExactCreditsWithoutContent() async throws {
        let stores = try inMemoryStores()
        let engine = ExactUsageEngine()
        let metered = MeteredInferenceEngine(
            base: engine, identifier: "local-test-model", stores: stores)
        var visible = ""
        for try await chunk in await metered.complete(
            messages: [
                ChatMessage(role: .user, content: "private synthetic prompt")
            ],
            tools: [],
            tier: .chat
        ) {
            if case .text(let text) = chunk { visible += text }
            if case .usage = chunk {
                Issue.record("Usage metadata must not leak into consumer output.")
            }
        }

        #expect(visible == "private synthetic response")
        let summary = try stores.localModelUsageSummary()
        #expect(summary.callsThisMonth == 1)
        #expect(summary.inputTokensThisMonth == 21)
        #expect(summary.outputTokensThisMonth == 8)
        #expect(summary.tokenCreditsThisMonth == 29)
        #expect(summary.estimatedCallsThisMonth == 0)
        let breakdown = try stores.localModelUsageBreakdown()
        #expect(breakdown.first?.engine == "local-test-model")
        #expect(breakdown.first?.tier == ModelTier.chat.rawValue)
        let persisted = String(decoding: try JSONEncoder().encode(
            try stores.recentLocalModelUsage()), as: UTF8.self)
        #expect(!persisted.contains("private synthetic prompt"))
        #expect(!persisted.contains("private synthetic response"))
    }
}

private final class SelectionBox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "aitvaras.tests.selection-box")
    private var value: CloudModelSelection

    init(_ value: CloudModelSelection) {
        self.value = value
    }

    func get() -> CloudModelSelection {
        queue.sync { value }
    }

    func set(_ newValue: CloudModelSelection) {
        queue.sync { value = newValue }
    }
}

private actor ExactUsageEngine: InferenceEngine {
    nonisolated let identifier = "exact-usage"

    func isAvailable(for tier: ModelTier) async -> Bool { true }

    func complete(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        tier: ModelTier
    ) -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("private synthetic response"))
            continuation.yield(.usage(InferenceUsage(
                inputTokens: 21, outputTokens: 8,
                modelIdentifier: "local-test-model")))
            continuation.yield(.done(stopReason: .endOfTurn))
            continuation.finish()
        }
    }
}
