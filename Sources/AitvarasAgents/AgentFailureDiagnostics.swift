import Foundation
import os
import AitvarasCore

/// Failure events carry this safe report after an error is caught. Full
/// errors stay at the catch site and are interpolated privately in unified log.
public struct AgentFailureReport: Error, Sendable, Equatable {
    public let failure: AgentFailure
    public let category: SafeErrorCategory
    public private(set) var isAudited = false

    public func activity(chatID: UUID, inputID: UUID?) -> ActivityEvent {
        var detail: [String: String] = ["chatID": chatID.uuidString,
            "errorType": category.type, "errorCase": category.errorCase]
        if let inputID { detail["inputID"] = inputID.uuidString }
        // One shared CLI transport failure can affect several chat inputs.
        // Each owner needs its own Activity identity, even for the same report.
        return ActivityEvent(kind: .agentFailure, connectorID: "agent", summary: "Chat turn failed",
            detailJSON: JSONValue.object(detail.mapValues(JSONValue.string)).jsonString, runID: inputID)
    }
    public func recording(chatID: UUID, inputID: UUID?,
                          audit: @Sendable (ActivityEvent) async throws -> Void) async -> Self {
        guard !isAudited else { return self }
        var result = self
        do {
            try await audit(activity(chatID: chatID, inputID: inputID))
            result.isAudited = true
        } catch {
            // A failed audit must not recurse into itself or replace the error
            // which stopped the turn. A downstream owner may still record it.
            AgentFailureDiagnostics.logPrivate(error)
        }
        return result
    }
}

public enum AgentFailureDiagnostics {
    private static let logger = Logger(subsystem: "Aitvaras", category: "AgentFailure")
    public static func logPrivate(_ error: any Error) {
        logger.error("Agent error: \(String(reflecting: error), privacy: .private)")
    }
    public static func capture(_ error: any Error, mappedTo: AgentFailure? = nil) -> AgentFailureReport {
        if let report = error as? AgentFailureReport { return report }
        logPrivate(error)
        return AgentFailureReport(failure: mappedTo ?? (error as? AgentFailure) ?? .unknown,
            category: SafeErrorCategory.category(for: error))
    }
    public static func failure(for error: any Error) -> AgentFailure {
        (error as? AgentFailureReport)?.failure ?? (error as? AgentFailure) ?? .unknown
    }
}

extension AgentFailure: SafeErrorCategorizing {
    public var safeErrorCategory: SafeErrorCategory {
        switch self {
        case .authRequired: .init(type: "AgentFailure", errorCase: "authRequired")
        case .quota: .init(type: "AgentFailure", errorCase: "quota")
        case .offline: .init(type: "AgentFailure", errorCase: "offline")
        case .notInstalled: .init(type: "AgentFailure", errorCase: "notInstalled")
        case .crashed: .init(type: "AgentFailure", errorCase: "crashed")
        case .unsupported: .init(type: "AgentFailure", errorCase: "unsupported")
        case .unapprovedProjectMCP: .init(type: "AgentFailure", errorCase: "unapprovedProjectMCP")
        case .invalidRequest: .init(type: "AgentFailure", errorCase: "invalidRequest")
        case .invalidTransition: .init(type: "AgentFailure", errorCase: "invalidTransition")
        case .unknown: .init(type: "AgentFailure", errorCase: "unknown")
        }
    }
}

extension AgentSessionManagerError: SafeErrorCategorizing {
    public var safeErrorCategory: SafeErrorCategory {
        switch self {
        case .chatBusy: .init(type: "AgentSessionManagerError", errorCase: "chatBusy")
        case .chatUnavailable: .init(type: "AgentSessionManagerError", errorCase: "chatUnavailable")
        case .runningChatLimit: .init(type: "AgentSessionManagerError", errorCase: "runningChatLimit")
        case .shuttingDown: .init(type: "AgentSessionManagerError", errorCase: "shuttingDown")
        case .missingSession: .init(type: "AgentSessionManagerError", errorCase: "missingSession")
        case .staleRun: .init(type: "AgentSessionManagerError", errorCase: "staleRun")
        case .persistence: .init(type: "AgentSessionManagerError", errorCase: "persistence")
        }
    }
}

extension AgentNativeHistoryError: SafeErrorCategorizing {
    public var safeErrorCategory: SafeErrorCategory {
        switch self {
        case .invalidCursor: .init(type: "AgentNativeHistoryError", errorCase: "invalidCursor")
        case .staleCursor: .init(type: "AgentNativeHistoryError", errorCase: "staleCursor")
        case .malformedHistory: .init(type: "AgentNativeHistoryError", errorCase: "malformedHistory")
        case .incompleteHistory: .init(type: "AgentNativeHistoryError", errorCase: "incompleteHistory")
        case .notFound: .init(type: "AgentNativeHistoryError", errorCase: "notFound")
        case .tooLarge: .init(type: "AgentNativeHistoryError", errorCase: "tooLarge")
        case .identityConflict: .init(type: "AgentNativeHistoryError", errorCase: "identityConflict")
        }
    }
}

extension AgentProcessError: SafeErrorCategorizing {
    public var safeErrorCategory: SafeErrorCategory {
        switch self {
        case .alreadyStarted: .init(type: "AgentProcessError", errorCase: "alreadyStarted")
        case .notStarted: .init(type: "AgentProcessError", errorCase: "notStarted")
        case .launchFailed: .init(type: "AgentProcessError", errorCase: "launchFailed")
        case .closed: .init(type: "AgentProcessError", errorCase: "closed")
        case .writeFailed: .init(type: "AgentProcessError", errorCase: "writeFailed")
        case .inputLimit: .init(type: "AgentProcessError", errorCase: "inputLimit")
        case .outputLimit: .init(type: "AgentProcessError", errorCase: "outputLimit")
        case .invalidUTF8: .init(type: "AgentProcessError", errorCase: "invalidUTF8")
        case .cleanupUnconfirmed: .init(type: "AgentProcessError", errorCase: "cleanupUnconfirmed")
        }
    }
}
