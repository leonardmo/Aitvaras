import Testing
import Foundation
@testable import AitvarasCore

@Test func activityEventProvenanceChain() {
    let mailArrived = ActivityEvent(
        kind: .eventReceived,
        connectorID: "mail",
        summary: "Mail from prof@example.edu",
        sourceID: "message-id-123"
    )
    let classified = ActivityEvent(
        kind: .classification,
        summary: "urgent, actionable",
        causedBy: mailArrived.id,
        sourceID: mailArrived.sourceID
    )
    #expect(classified.causedBy == mailArrived.id)
    #expect(classified.sourceID == "message-id-123")
}

@Test func activityEventRoundTripsThroughJSON() throws {
    let event = ActivityEvent(kind: .toolExecuted, connectorID: "calendar", summary: "Created event")
    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(ActivityEvent.self, from: data)
    #expect(decoded == event)
}

@Test func actionRiskIsStableInSerializedForm() throws {
    // Risk levels are persisted in the activity log and tool definitions;
    // their raw values must not drift.
    #expect(ActionRisk.read.rawValue == "read")
    #expect(ActionRisk.reversibleWrite.rawValue == "reversibleWrite")
    #expect(ActionRisk.confirmable.rawValue == "confirmable")
}
