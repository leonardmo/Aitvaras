import Foundation
import Observation
import AitvarasCore
import AitvarasAgents
import AitvarasConnectors
import AitvarasStore

/// Discovery state for read-only native histories. Every provider read is an
/// explicit click: nothing here resumes, controls or writes a native session,
/// and saved text stays separate from the local chat and its prompts.
@MainActor
@Observable
final class NativeWorkspaceModel {
    static let savedPageSize = 100
    private static let maximumPreviewPages = 100

    var provider: NativeSessionProvider = .codex {
        didSet { if provider != oldValue { invalidateBrowser() } }
    }
    var archived = false {
        didSet { if archived != oldValue { invalidateBrowser() } }
    }

    let operations = NativeHistoryOperationCoordinator()
    var reporter: ActivityReporter? {
        get { operations.reporter }
        set { operations.reporter = newValue }
    }
    var isBusy: Bool { operations.isBusy }
    var isCancelling: Bool { operations.isCancelling }
    var activeRunID: UUID? { operations.activeRunID }
    @ObservationIgnored var readerFactory: @Sendable (NativeSessionProvider) -> any NativeSessionReader = {
        NativeWorkspaceModel.reader(for: $0)
    }
    @ObservationIgnored var sdkInstaller: @Sendable () async throws -> NativeSessionCapability = {
        try await ClaudeSessionReader.installSDK()
    }

    private(set) var capabilities: [NativeSessionCapability] = []
    private(set) var status: String?
    private(set) var errorMessage: String?

    private struct Filter: Equatable {
        let provider: NativeSessionProvider
        let archived: Bool
    }
    private var filter: Filter { Filter(provider: provider, archived: archived) }
    private var browserRevision = UUID()
    private var listedFilter: Filter?
    private var listedSessions: [NativeSessionSummary] = []
    private var listedCursor: String?

    /// Preview pages keep their fetch order: import replays them with the same
    /// continuation cursors the provider returned.
    private(set) var previewPages: [NativeTranscriptPage] = [] {
        didSet { previewRevision = UUID() }
    }
    /// Consent is tied to these exact reviewed pages, not a message count.
    private(set) var previewRevision = UUID()

    // Saved-snapshot caches. Views read these instead of touching the database
    // while rendering; AppModel fills them from Stores.
    var links: [UUID: [WorkspaceSessionLink]] = [:]
    var snapshots: [UUID: WorkspaceNativeSnapshot] = [:]
    var savedMessages: [UUID: [WorkspaceNativeMessage]] = [:]
    var savedCounts: [UUID: Int] = [:]
    var savedLimits: [UUID: Int] = [:]

    nonisolated static func reader(for provider: NativeSessionProvider) -> any NativeSessionReader {
        let environment = ProcessInfo.processInfo.environment
        let agent: AgentProvider = provider == .claude ? .claude : .codex
        guard AgentProviderLaunchPolicy.allows(agent, environment: environment, isolated: AitvarasPaths.isIsolated) else {
            return NativeBackendSessionReader(provider: provider, backend: nil)
        }
        switch provider {
        case .codex: return NativeBackendSessionReader(provider: .codex, backend: CodexBackend())
        case .claude: return NativeBackendSessionReader(provider: .claude, backend: ClaudeBackend())
        }
    }

    func makeReader(for provider: NativeSessionProvider) -> any NativeSessionReader { readerFactory(provider) }

    var sessions: [NativeSessionSummary] { listedFilter == filter ? listedSessions : [] }
    var sessionNextCursor: String? { listedFilter == filter ? listedCursor : nil }

    var previewSession: NativeSessionSummary? {
        guard let session = previewPages.first?.session, session.provider == provider else { return nil }
        return session
    }

    /// The preview and persistence share one exact, validated text projection.
    var previewMessages: [NativeTextMessage] {
        guard previewSession != nil else { return [] }
        return (try? canonicalNativeReview(previewPages).messages) ?? []
    }

    var previewCoverage: String {
        guard previewSession != nil, let page = previewPages.last else { return "" }
        return page.coverage
    }

    var previewNextCursor: String? {
        guard previewSession != nil, previewPages.count < Self.maximumPreviewPages else { return nil }
        return previewPages.last?.nextCursor
    }

    func checkCapabilities() async {
        guard !isBusy else { return }
        let target = provider
        let revision = browserRevision
        beginTask("Checking the \(target.displayName) setup…")
        do {
            try await operations.run(title: "Check native history setup", provider: target,
                dataAccess: "Local runtime and SDK availability", dataDestination: "Local setup view") {
                self.operations.updateProgress(stage: "Checking local setup")
                let capability = await self.makeReader(for: target).capabilities()
                try self.requireCurrent(revision)
                self.record(capability)
                self.endTask("Setup check finished. Preview verifies transcript support.")
            }
        } catch { reportBrowserError(error, revision: revision) }
    }

    func loadSessions(reset: Bool = true) async {
        guard !isBusy else { return }
        let target = provider
        let requestedFilter = filter
        let revision = browserRevision
        let continuing = !reset && listedFilter == requestedFilter
        let cursor = continuing ? listedCursor : nil
        if !reset, cursor == nil { return }
        beginTask(continuing ? "Loading more \(target.displayName) chats…" : "Listing \(target.displayName) chats…")
        do {
            try await operations.run(title: continuing ? "Load more native history chats" : "List native history chats",
                provider: target, dataAccess: "Native chat metadata", dataDestination: "Local history browser") {
                self.operations.updateProgress(stage: "Listing chat metadata")
                let page = try await self.makeReader(for: target)
                    .listSessions(cursor: cursor, archived: target == .codex && requestedFilter.archived)
                try self.requireCurrent(revision)
                if !continuing {
                    self.listedFilter = requestedFilter
                    self.listedSessions = []
                }
                var seen = Set(self.listedSessions.map(\.id))
                self.listedSessions += page.sessions.filter { $0.provider == target && seen.insert($0.id).inserted }
                let next = page.nextCursor
                self.listedCursor = (next?.isEmpty ?? true) || next == cursor ? nil : next
                self.operations.updateProgress(stage: "Chat metadata loaded", completed: self.listedSessions.count)
                self.endTask("\(self.listedSessions.count) listed · \(page.coverage)")
            }
        } catch { reportBrowserError(error, revision: revision) }
    }

    func preview(_ session: NativeSessionSummary) async {
        guard !isBusy, session.provider == provider else { return }
        let revision = browserRevision
        beginTask("Reading \(session.provider.displayName) text…")
        previewPages = []
        do {
            try await operations.run(title: "Preview native history", provider: session.provider,
                dataAccess: "Native chat text", dataDestination: "Local preview; not saved") {
                self.operations.updateProgress(stage: "Reading text page")
                let page = try await self.makeReader(for: session.provider)
                    .readSession(id: session.externalID, directory: session.directory, cursor: nil)
                try self.requireCurrent(revision)
                try Self.verify(page.session, matches: session)
                let review = try canonicalNativeReview([page])
                self.previewPages = [page]
                self.operations.updateProgress(stage: "Text ready for review", completed: review.messages.count)
                self.endTask("\(review.messages.count) text messages loaded · \(page.coverage)")
            }
        } catch { reportBrowserError(error, revision: revision) }
    }

    func loadMorePreview() async {
        guard !isBusy, let session = previewSession, let cursor = previewNextCursor else { return }
        let revision = browserRevision
        let pages = previewPages
        beginTask("Reading more \(session.provider.displayName) text…")
        do {
            try await operations.run(title: "Load more native history preview", provider: session.provider,
                dataAccess: "Native chat text", dataDestination: "Local preview; not saved") {
                self.operations.updateProgress(stage: "Reading text page", completed: pages.count)
                let page = try await self.makeReader(for: session.provider)
                    .readSession(id: session.externalID, directory: session.directory, cursor: cursor)
                try self.requireCurrent(revision)
                try Self.verify(page.session, matches: session)
                guard page.nextCursor != cursor else { throw NativeWorkspaceError.stalePage }
                let updated = pages + [page]
                let review = try canonicalNativeReview(updated)
                self.previewPages = updated
                self.operations.updateProgress(stage: "Text ready for review", completed: review.messages.count)
                self.endTask("\(review.messages.count) text messages loaded · \(page.coverage)")
            }
        } catch { reportBrowserError(error, revision: revision) }
    }

    func installClaudeSDK() async {
        guard !isBusy else { return }
        let revision = browserRevision
        beginTask("Setting up the official Claude Code SDK…")
        do {
            try await operations.run(title: "Install native history SDK", provider: .claude,
                dataAccess: "Public SDK packages; no native history", dataDestination: "Private local SDK installation; npm registry download") {
                self.operations.updateProgress(stage: "Downloading and installing SDK")
                let capability = try await self.sdkInstaller()
                try self.requireCurrent(revision)
                self.record(capability)
                self.operations.updateProgress(stage: "SDK installation verified", completed: 1, total: 1)
                self.endTask("Claude Code SDK setup finished.")
            }
        } catch { reportBrowserError(error, revision: revision) }
    }

    func clearPreview() {
        browserRevision = UUID()
        operations.cancelBrowserOperation()
        previewPages = []
        status = nil
        errorMessage = nil
    }

    func cancelBrowserOperation() { operations.cancelBrowserOperation() }

    private func invalidateBrowser() {
        clearPreview()
        listedFilter = nil
        listedSessions = []
        listedCursor = nil
    }

    private func requireCurrent(_ revision: UUID) throws {
        try Task.checkCancellation()
        guard browserRevision == revision else { throw CancellationError() }
    }

    private func reportBrowserError(_ error: Error, revision: UUID) {
        guard browserRevision == revision else { return }
        report(error: error)
    }

    /// Synthetic seam for isolated QA profiles: stages already reviewed pages
    /// without a native provider. Unreachable in a normal run.
    func stageSyntheticPreview(_ pages: [NativeTranscriptPage]) {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        if let provider = pages.first?.session.provider { self.provider = provider }
        previewPages = pages
    }

    func beginTask(_ message: String) {
        status = message
        errorMessage = nil
    }

    func endTask(_ message: String?) {
        if let message { status = message }
    }

    func report(status message: String?) {
        status = message
        errorMessage = nil
    }

    func report(error: Error) {
        status = nil
        if error is CancellationError {
            errorMessage = nil
            status = "Native history operation cancelled."
        } else {
            // Do not surface untrusted provider diagnostics or filesystem paths.
            errorMessage = (error as? NativeWorkspaceError)?.errorDescription
                ?? (error as? NativeHistoryReviewError)?.errorDescription
                ?? (error as? NativeHistoryRefresh.RefreshError)?.errorDescription
                ?? (error as? WorkspaceNativeError)?.errorDescription
                ?? "Native history could not be loaded. Check setup and try again."
        }
    }

    private func record(_ capability: NativeSessionCapability) {
        capabilities.removeAll { $0.provider == capability.provider }
        capabilities.append(capability)
    }

    private static func verify(_ source: NativeSessionSummary, matches expected: NativeSessionSummary) throws {
        guard source.provider == expected.provider, source.hostID == expected.hostID,
              source.externalID == expected.externalID else { throw NativeWorkspaceError.sourceMismatch }
    }
}

enum NativeWorkspaceError: LocalizedError {
    case sourceMismatch, stalePage, unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .sourceMismatch: "The native source returned a different chat. Nothing was saved."
        case .stalePage: "History changed while paging. Refresh the source and try again."
        case .unsupportedProvider: "This linked provider has no supported read-only history reader."
        }
    }
}
