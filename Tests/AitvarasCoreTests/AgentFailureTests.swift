import Foundation
import Testing
import AitvarasAgents

@Suite struct AgentFailureTests {
    @Test func capacityAndSignInMessagesAreSpecific() {
        #expect(AgentFailure.sendMessage(for: AgentSessionManagerError.runningChatLimit, provider: .codex)
                == "8 chats are running. Stop one or wait.")
        #expect(AgentFailure.sendMessage(for: AgentFailure.authRequired, provider: .claude) == "Sign in to Claude")
        #expect(AgentFailure.sendMessage(for: AgentFailure.authRequired, provider: .codex) == "Sign in to Codex")
    }

    @Test func knownSendFailuresDoNotUseUnknownFallback() {
        let errors: [any Error] = [
            AgentFailure.authRequired, AgentFailure.quota(resetsAt: nil), AgentFailure.offline,
            AgentFailure.notInstalled, AgentFailure.crashed(exitCode: 1), AgentFailure.unsupported,
            AgentFailure.invalidRequest, AgentFailure.invalidTransition,
            AgentSessionManagerError.chatBusy, AgentSessionManagerError.chatUnavailable,
            AgentSessionManagerError.runningChatLimit, AgentSessionManagerError.shuttingDown,
            AgentSessionManagerError.missingSession, AgentSessionManagerError.staleRun, AgentSessionManagerError.persistence,
            AgentNativeHistoryError.invalidCursor, AgentNativeHistoryError.staleCursor,
            AgentNativeHistoryError.malformedHistory, AgentNativeHistoryError.incompleteHistory,
            AgentNativeHistoryError.notFound, AgentNativeHistoryError.tooLarge, AgentNativeHistoryError.identityConflict,
            AgentGitError.commandFailed, AgentGitError.invalidOutput, AgentGitError.notRepository,
            AgentGitError.ownershipConflict, AgentGitError.creationFailed, AgentGitError.staleChanges,
            AgentGitError.busy, AgentGitError.confirmationRequired, AgentGitError.emptyMessage, AgentGitError.noChanges,
            AgentProcessError.alreadyStarted, AgentProcessError.notStarted, AgentProcessError.launchFailed,
            AgentProcessError.closed, AgentProcessError.writeFailed, AgentProcessError.inputLimit,
            AgentProcessError.outputLimit, AgentProcessError.invalidUTF8, AgentProcessError.cleanupUnconfirmed,
            AgentAttachmentError.missingFile, AgentAttachmentError.tooLarge,
            AgentAttachmentError.unsupportedType, AgentAttachmentError.tooMany,
            CancellationError()
        ]
        for error in errors {
            let message = AgentFailure.sendMessage(for: error, provider: .codex)
            #expect(!message.isEmpty)
            #expect(message != "Message could not be sent.")
        }
    }

    @Test func unknownFailuresNeverExposeRawDiagnostics() {
        let unknown = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Raw fixture diagnostics"])
        #expect(AgentFailure.sendMessage(for: unknown, provider: .codex) == "Message could not be sent.")
        #expect(AgentFailure.sendMessage(for: AgentFailure.unknown, provider: .claude) == "Message could not be sent.")
    }
}
