import Foundation
import AitvarasCore
import AitvarasStore

/// Bootstrap-free integration checks: only synthetic readers and an in-memory
/// database. No native accounts, models, recordings or runtime downloads.
@MainActor
enum NativeHistoryFixCheck {
    static func run(_ model: AppModel) async throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        try model.prepareMonitoringFixture("idle")
        guard let stores = model.stores else { throw FixError.failed }
        let browser = model.nativeWorkspace
        defer { browser.readerFactory = { NativeWorkspaceModel.reader(for: $0) } }
        let source = NativeSessionSummary(provider: .codex, externalID: "synthetic-native-fixes",
            title: "Synthetic history", directory: "/tmp/aitvaras-history-fixture",
            updatedAt: Date(timeIntervalSince1970: 1_000))
        let first = page(source, messages: [message(0), message(1)], cursor: "page-2")
        let last = page(source, messages: [message(2), message(3)])
        let metadata = NativeSessionPage(sessions: [source], nextCursor: "list-2", coverage: "Synthetic metadata only")
        let reader = FixReader(metadata: metadata, pages: ["initial": first, "page-2": last])
        browser.readerFactory = { _ in reader }

        await browser.loadSessions()
        try require(browser.sessions.count == 1 && browser.sessionNextCursor == "list-2")
        browser.stageSyntheticPreview([first])
        browser.archived = true
        try require(browser.sessions.isEmpty && browser.sessionNextCursor == nil && browser.previewPages.isEmpty)
        await browser.loadSessions(reset: false)
        try require(await reader.listCalls() == 1)

        // A filter changed away and back must still reject an old response.
        browser.archived = false
        let listGate = FixGate()
        let delayed = FixReader(metadata: metadata, pages: [:], listGate: listGate)
        browser.readerFactory = { _ in delayed }
        let listing = Task { await browser.loadSessions() }
        await listGate.waitForEntry()
        browser.archived = true
        browser.archived = false
        try require(browser.isBusy && browser.sessions.isEmpty)
        await listGate.release()
        await listing.value
        try require(!browser.isBusy && browser.sessions.isEmpty && browser.sessionNextCursor == nil)

        browser.stageSyntheticPreview([first])
        let oldRevision = browser.previewRevision
        var changed = first
        changed.messages[0].text = "Different text, same count"
        browser.stageSyntheticPreview([changed])
        try require(browser.previewRevision != oldRevision && browser.previewMessages[0].text == changed.messages[0].text)

        // Conflicting overlap is rejected, not hidden behind a first-wins UI.
        browser.stageSyntheticPreview([first])
        let reviewedRevision = browser.previewRevision
        let overlap = page(source, messages: [.init(externalID: "message-1", role: .assistant, text: "Unreviewed changed text")])
        let conflicting = FixReader(metadata: metadata, pages: ["page-2": overlap])
        browser.readerFactory = { _ in conflicting }
        await browser.loadMorePreview()
        try require(browser.previewPages == [first] && browser.previewRevision == reviewedRevision && browser.errorMessage != nil)

        try require(model.createWorkspaceProject(title: "Native fixes fixture", instructions: "", folderURLs: []))
        guard let projectID = model.selectedWorkspaceProjectID else { throw FixError.failed }
        browser.stageSyntheticPreview([first, last])
        try require(!model.importPreviewedNativeSession(projectID: projectID, kind: .primary, reviewedRevision: oldRevision))
        try require(model.importPreviewedNativeSession(projectID: projectID, kind: .primary, reviewedRevision: browser.previewRevision))
        guard let chatID = model.selectedWorkspaceChatID,
              let link = model.nativeSessionLinks(for: chatID).first else { throw FixError.failed }
        let initialMessages = try stores.workspaceNativeMessages(linkID: link.id)
        try require(model.messages.isEmpty && model.nativeSnapshot(linkID: link.id)?.lastCompleteRefreshAt == nil)

        var updatedSource = source
        updatedSource.updatedAt = Date(timeIntervalSince1970: 2_000)
        var updatedTail = message(3)
        updatedTail.text = "Edited tail beyond the first page"
        let refreshedFirst = page(updatedSource, messages: [message(0), message(1)], cursor: "page-2")
        let refreshedLast = page(updatedSource, messages: [message(2), updatedTail, message(4)])
        let refreshReader = FixReader(metadata: metadata, pages: ["initial": refreshedFirst, "page-2": refreshedLast])
        browser.readerFactory = { _ in refreshReader }
        await model.refreshNativeSession(linkID: link.id, loadMore: false)
        let refreshed = try stores.workspaceNativeMessages(linkID: link.id)
        try require(refreshed.count == 5 && model.nativeMessages(linkID: link.id).count == 5)
        try require(refreshed[3].text == updatedTail.text && refreshed[3].id == initialMessages[3].id && refreshed[3].revision == 2)
        try require(model.nativeSnapshot(linkID: link.id)?.lastCompleteRefreshAt != nil)

        let beforeCancel = try stores.workspaceNativeSnapshot(linkID: link.id)
        let readGate = FixGate()
        let slow = FixReader(metadata: metadata, pages: ["initial": refreshedFirst, "page-2": refreshedLast], readGate: readGate)
        browser.readerFactory = { _ in slow }
        let refreshTask = Task { await model.refreshNativeSession(linkID: link.id, loadMore: false) }
        await readGate.waitForEntry()
        guard let runID = browser.activeRunID, let run = try stores.activityRun(id: runID) else { throw FixError.failed }
        try require(run.state == .running && model.canStopActivityRun(run))
        model.refreshMonitoring()
        model.cancelActivityRun(runID)
        try require(browser.isBusy && browser.isCancelling && (try stores.activityRun(id: runID))?.state == .cancellationRequested)
        await readGate.release()
        await refreshTask.value
        try require(!browser.isBusy && (try stores.activityRun(id: runID))?.state == .cancelled)
        try require((try stores.workspaceNativeSnapshot(linkID: link.id)) == beforeCancel)
        try require((try stores.workspaceNativeMessages(linkID: link.id)) == refreshed)
        try require((try stores.messages(in: model.selectedChatConversationID!)).isEmpty)
        print("[native-history-fixes] PASS: filter generations, exact review, Activity, complete refresh, cached revisions and cancellation rollback")
    }

    private static func message(_ number: Int) -> NativeTextMessage {
        .init(externalID: "message-\(number)", role: number.isMultiple(of: 2) ? .user : .assistant, text: "Synthetic text \(number)")
    }
    private static func page(_ source: NativeSessionSummary, messages: [NativeTextMessage], cursor: String? = nil) -> NativeTranscriptPage {
        .init(session: source, messages: messages, nextCursor: cursor, coverage: "Synthetic text only", direction: .newer)
    }
    private static func require(_ value: Bool) throws { guard value else { throw FixError.failed } }
    private enum FixError: Error { case failed }
}

private actor FixGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        entryWaiter?.resume(); entryWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() {
        released = true
        releaseWaiter?.resume(); releaseWaiter = nil
    }
}

private actor FixReader: NativeSessionReader {
    nonisolated let provider: NativeSessionProvider = .codex
    let metadata: NativeSessionPage
    let pages: [String: NativeTranscriptPage]
    let listGate: FixGate?
    let readGate: FixGate?
    private var lists = 0
    init(metadata: NativeSessionPage, pages: [String: NativeTranscriptPage], listGate: FixGate? = nil, readGate: FixGate? = nil) {
        self.metadata = metadata; self.pages = pages; self.listGate = listGate; self.readGate = readGate
    }
    func capabilities() async -> NativeSessionCapability { .init(provider: .codex, state: .ready, detail: "Synthetic") }
    func listSessions(cursor: String?, archived: Bool) async throws -> NativeSessionPage {
        lists += 1
        await listGate?.wait()
        return metadata
    }
    func listCalls() -> Int { lists }
    func readSession(id: String, directory: String?, cursor: String?) async throws -> NativeTranscriptPage {
        if cursor == "page-2" { await readGate?.wait() }
        guard let page = pages[cursor ?? "initial"] else { throw FixtureError.missingPage }
        return page
    }
    private enum FixtureError: Error { case missingPage }
}
