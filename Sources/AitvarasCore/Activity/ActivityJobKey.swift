import Foundation

/// Stable metadata for background job owners. Subjects are local record IDs,
/// source/model identifiers or existing fingerprints, never display text or paths.
/// Hash subjects so the persisted key cannot copy their text into telemetry.
public enum ActivityJobKey {
    private enum Operation: String {
        case startup = "startup.application"
        case captureAudioMaintenance = "startup.capture-audio"
        case voiceHelperCleanup = "startup.voice-helper"
        case consolidation = "memory.consolidation"
        case indexing = "knowledge.indexing"
        case archiving = "memory.archiving"
        case captureSummary = "capture.summary"
        case captureRefinement = "capture.refinement"
        case modelPreparation = "model.preparation"
        case modelDownload = "model.download"
        case speechAssets = "model.speech-assets"
        case voiceInstallation = "model.voice-installation"
        case routineExecution = "routine.execution"
        case routineReview = "routine.review"
        case queuedDelivery = "delivery.queued"
        case backgroundProblem = "background.problem"
    }

    public static let startup = key(.startup)
    public static let captureAudioMaintenance = key(.captureAudioMaintenance)
    public static let voiceHelperCleanup = key(.voiceHelperCleanup)
    public static let consolidation = key(.consolidation)
    public static let voiceInstallation = key(.voiceInstallation)

    public static func indexing(sourceIDs: [String]) -> String {
        key(.indexing, subjects: Array(Set(sourceIDs)).sorted())
    }

    public static func archiving(conversationID: UUID, fingerprint: String) -> String {
        key(.archiving, subjects: [conversationID.uuidString, fingerprint])
    }

    public static func captureSummary(recordID: UUID) -> String {
        key(.captureSummary, subjects: [recordID.uuidString])
    }

    public static func captureRefinement(archiveID: UUID, modelID: String, language: CaptureLanguage) -> String {
        key(.captureRefinement, subjects: [archiveID.uuidString, modelID, language.rawValue])
    }

    public static func modelPreparation(modelID: String) -> String {
        key(.modelPreparation, subjects: [modelID])
    }

    public static func modelDownload(modelID: String, repository: String, revision: String) -> String {
        key(.modelDownload, subjects: [modelID, repository, revision])
    }

    public static func speechAssets(language: CaptureLanguage) -> String {
        key(.speechAssets, subjects: [language.rawValue])
    }

    public static func routineExecution(routineID: UUID) -> String {
        key(.routineExecution, subjects: [routineID.uuidString])
    }

    /// The existing reviewer submits a batch; provider attempts retain that batch's identity.
    public static func routineReview(routineIDs: [UUID]) -> String {
        key(.routineReview, subjects: Array(Set(routineIDs.map(\.uuidString))).sorted())
    }

    public static func queuedDelivery(itemID: UUID) -> String {
        key(.queuedDelivery, subjects: [itemID.uuidString])
    }

    public static func problem(_ code: ActivityProblemCode, subjectID: UUID? = nil) -> String {
        key(.backgroundProblem, subjects: [code.rawValue] + (subjectID.map { [$0.uuidString] } ?? []))
    }

    /// Archiving keys hash their subject, so only the operation is recognizable
    /// here; the archiver recomputes the full key before any retry.
    public static func isArchiving(_ key: String) -> Bool {
        key.hasPrefix(Operation.archiving.rawValue + ":")
    }

    private static func key(_ operation: Operation, subjects: [String] = []) -> String {
        subjects.isEmpty ? operation.rawValue : operation.rawValue + ":" + StableIdentifier.digest(subjects)
    }
}

/// Explicit incident identities, independent of their user-facing explanation.
public enum ActivityProblemCode: String, Sendable {
    case archiveRecovery, routineReview, conversationArchive, voiceArchive, wakeBriefing
    case chatWakeup, pullRequestWatch, routineExecution, indexing, incomingLookup, senderTrustLookup, incomingSave
    case notificationQueue, phoneQueueRead, phoneQueueUpdate, phoneRetrySchedule, phoneResultSave
    case savedNativeHistory, heldNotificationSave, heldNotificationRead, heldNotificationConsume
    case focusRestore, focusChange, focusRefresh, focusSummaryGoals, focusCoachingGoals
    case focusShortcutRead, focusShortcutExecution, focusActivitySave
}
