import Foundation
import Testing
import AitvarasCore
import AitvarasStore

@Suite struct TodaySnapshotTests {
    @Test func snapshotSelectsTodayAndBoundsGlanceableLists() throws {
        let stores = try inMemoryStores()
        let day = "2031-02-03"
        let currentGoal = Goal(day: day, text: "Finish the write-up")
        try stores.saveGoal(currentGoal)
        try stores.saveGoal(Goal(day: "2031-02-02", text: "Old goal"))

        let olderSuggestion = Suggestion(
            createdAt: Date(timeIntervalSince1970: 10), title: "Older", detail: "",
            connectorID: "calendar", toolName: "create_event", argumentsJSON: "{}")
        let newerSuggestion = Suggestion(
            createdAt: Date(timeIntervalSince1970: 20), title: "Newer", detail: "",
            connectorID: "calendar", toolName: "create_event", argumentsJSON: "{}")
        try stores.saveSuggestion(olderSuggestion)
        try stores.saveSuggestion(newerSuggestion)
        try stores.saveSuggestion(Suggestion(
            title: "Already handled", detail: "", connectorID: "calendar",
            toolName: "create_event", argumentsJSON: "{}", status: "executed"))

        let lowerValue = CuriosityQuestion(text: "Lower value", expectedValue: 3)
        let higherValue = CuriosityQuestion(text: "Higher value", expectedValue: 9)
        try stores.saveQuestion(lowerValue)
        try stores.saveQuestion(higherValue)

        let held = HeldNotification(title: "While focused", body: "One update")
        try stores.holdNotification(held, recording: ActivityEvent(
            kind: .eventReceived, summary: "Update held"))

        try stores.saveFact(MemoryFact(text: "Prefers quiet mornings"))
        let oldRun = ActivityEvent(
            kind: .consolidationRun, timestamp: Date(timeIntervalSince1970: 30),
            summary: "Nightly consolidation: old")
        let latestRun = ActivityEvent(
            kind: .consolidationRun, timestamp: Date(timeIntervalSince1970: 40),
            summary: "Nightly consolidation: latest")
        try stores.record(oldRun)
        try stores.record(latestRun)
        let completedAt = Date(timeIntervalSince1970: 50)
        try stores.setValue(
            String(completedAt.timeIntervalSince1970),
            forKey: "consolidator.lastRun")

        let snapshot = try stores.todaySnapshot(
            day: day, suggestionLimit: 1, questionLimit: 1,
            heldNotificationLimit: 1)

        #expect(snapshot.goals.map(\.id) == [currentGoal.id])
        #expect(snapshot.pendingSuggestions.map(\.id) == [newerSuggestion.id])
        #expect(snapshot.pendingSuggestionCount == 2)
        #expect(snapshot.openQuestions.map(\.id) == [higherValue.id])
        #expect(snapshot.openQuestionCount == 2)
        #expect(snapshot.heldNotifications.map(\.id) == [held.id])
        #expect(snapshot.heldNotificationCount == 1)
        #expect(snapshot.latestConsolidation?.id == latestRun.id)
        #expect(snapshot.lastConsolidationCompletedAt == completedAt)
        #expect(!snapshot.consolidationNeedsAttention)
        #expect(snapshot.activeMemoryCount == 1)
    }

    @Test func snapshotAllowsCountOnlyReadsAndClampsNegativeLimits() throws {
        let stores = try inMemoryStores()
        try stores.saveQuestion(CuriosityQuestion(text: "Still counted"))
        try stores.saveSuggestion(Suggestion(
            title: "Still counted", detail: "", connectorID: "calendar",
            toolName: "create_event", argumentsJSON: "{}"))
        try stores.holdNotification(
            HeldNotification(title: "Still counted", body: "Body"),
            recording: ActivityEvent(kind: .eventReceived, summary: "Held"))

        let snapshot = try stores.todaySnapshot(
            day: "2031-02-03", suggestionLimit: -1, questionLimit: -1,
            heldNotificationLimit: -1)

        #expect(snapshot.pendingSuggestions.isEmpty)
        #expect(snapshot.pendingSuggestionCount == 1)
        #expect(snapshot.openQuestions.isEmpty)
        #expect(snapshot.openQuestionCount == 1)
        #expect(snapshot.heldNotifications.isEmpty)
        #expect(snapshot.heldNotificationCount == 1)
    }

    @Test func onlyAnUnrecoveredConsolidationFailureNeedsAttention() throws {
        let stores = try inMemoryStores()
        let completedAt = Date(timeIntervalSince1970: 100)
        try stores.setValue(
            String(completedAt.timeIntervalSince1970),
            forKey: "consolidator.lastRun")
        try stores.record(ActivityEvent(
            kind: .consolidationRun,
            timestamp: Date(timeIntervalSince1970: 110),
            summary: "Nightly consolidation FAILED: engine unavailable — will retry"))

        #expect(try stores.todaySnapshot().consolidationNeedsAttention)

        try stores.setValue("120", forKey: "consolidator.lastRun")
        let recovered = try stores.todaySnapshot()
        #expect(!recovered.consolidationNeedsAttention)
        #expect(recovered.lastConsolidationCompletedAt == Date(timeIntervalSince1970: 120))
    }
}
