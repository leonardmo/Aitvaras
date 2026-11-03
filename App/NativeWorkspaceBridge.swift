import Foundation
import AitvarasCore
import AitvarasConnectors
import AitvarasStore

/// Bridges reviewed native history into the workspace. Importing stores the
/// loaded text locally and grants no folder, tool, cloud or control permission.
extension AppModel {
    func nativeSessionLinks(for chatID: UUID) -> [WorkspaceSessionLink] {
        nativeWorkspace.links[chatID] ?? []
    }

    func nativeSnapshot(linkID: UUID) -> WorkspaceNativeSnapshot? {
        nativeWorkspace.snapshots[linkID]
    }

    func nativeMessages(linkID: UUID) -> [WorkspaceNativeMessage] {
        nativeWorkspace.savedMessages[linkID] ?? []
    }

    func nativeHasMoreSavedMessages(linkID: UUID) -> Bool {
        nativeMessages(linkID: linkID).count < (nativeWorkspace.savedCounts[linkID] ?? 0)
    }

    /// Shows another page of text already saved on this Mac. This never reads
    /// the native provider.
    func loadMoreSavedNativeMessages(linkID: UUID) {
        guard nativeHasMoreSavedMessages(linkID: linkID) else { return }
        nativeWorkspace.savedLimits[linkID] = savedNativeLimit(linkID) + NativeWorkspaceModel.savedPageSize
        do { try refreshNativeSnapshot(id: linkID) }
        catch { reportSavedNativeHistoryFailure() }
    }

    /// Keeps the session links of the visible chats, and their saved snapshots,
    /// in step with the database. Called from workspace refreshes, not a timer.
    func refreshNativeLinks() {
        guard let stores else { return }
        var map: [UUID: [WorkspaceSessionLink]] = [:]
        do {
            for chat in workspaceChats {
                let links = try stores.workspaceSessionLinks(chatID: chat.id).filter { $0.provider != .local }
                if !links.isEmpty { map[chat.id] = links }
            }
        } catch { reportSavedNativeHistoryFailure(); return }
        nativeWorkspace.links = map
        let live = Set(map.values.flatMap { $0.map(\.id) })
        nativeWorkspace.snapshots = nativeWorkspace.snapshots.filter { live.contains($0.key) }
        nativeWorkspace.savedMessages = nativeWorkspace.savedMessages.filter { live.contains($0.key) }
        nativeWorkspace.savedCounts = nativeWorkspace.savedCounts.filter { live.contains($0.key) }
        nativeWorkspace.savedLimits = nativeWorkspace.savedLimits.filter { live.contains($0.key) }
        for id in live where nativeWorkspace.savedMessages[id] == nil {
            do { try refreshNativeSnapshot(id: id) }
            catch { reportSavedNativeHistoryFailure() }
        }
    }

    /// Imports the reviewed preview pages. The caller must have displayed the
    /// text and collected explicit confirmation first.
    @discardableResult
    func importPreviewedNativeSession(projectID: UUID, kind: WorkspaceChat.Kind, reviewedRevision: UUID) -> Bool {
        guard !isWorkspaceSelectionBusy, !nativeWorkspace.isBusy else {
            workspaceMessage = "Finish or stop the active response or voice conversation before importing."
            return false
        }
        guard let stores else { return false }
        guard reviewedRevision == nativeWorkspace.previewRevision else {
            workspaceMessage = "The preview changed. Review the loaded text again before importing."
            return false
        }
        let pages = nativeWorkspace.previewPages
        let count = nativeWorkspace.previewMessages.count
        guard !pages.isEmpty, count > 0 else { return false }
        // The transaction itself is synchronous and cannot safely stop halfway.
        // It is visible in History, but never advertises an unsupported Stop.
        let runID = activityReporter?.begin(ActivityRun(referenceID: projectID.uuidString,
            category: .connection, trigger: .manual, title: "Import reviewed native history",
            stage: "Saving reviewed text atomically", provider: pages.first?.session.provider.displayName,
            executionLocation: "This Mac", dataAccess: "User-reviewed native history text",
            dataDestination: "Local project history; no model or native-session changes"))
        do {
            let chat = try stores.importWorkspaceNativeSession(pages: pages, projectID: projectID,
                kind: kind, reviewed: true)
            nativeWorkspace.clearPreview()
            workspaceMessage = nil
            openWorkspaceChat(chat.id)
            // Re-import can update an existing link. Replace its cached text,
            // not just the database rows, before showing completion.
            for link in nativeSessionLinks(for: chat.id) {
                do { try refreshNativeSnapshot(id: link.id) }
                catch { reportSavedNativeHistoryFailure() }
            }
            nativeWorkspace.report(status: "Saved \(count) text messages as a read-only source in \(chat.title).")
            if let runID { activityReporter?.finish(id: runID, state: .succeeded,
                outcome: "Reviewed text saved locally; no provider session changed") }
            return true
        } catch {
            workspaceMessage = "Native history was not imported. Review the source and destination, then try again."
            if let runID { activityReporter?.finish(id: runID, state: .failed,
                outcome: "Import failed; the transaction retained previous history") }
            return false
        }
    }

    /// Reads the native provider again for one linked source. `loadMore`
    /// continues the saved cursor. A complete refresh traverses and verifies
    /// every currently exposed page before changing any saved text/freshness.
    func refreshNativeSession(linkID: UUID, loadMore: Bool) async {
        guard let stores, !nativeWorkspace.isBusy else { return }
        guard let link = nativeWorkspace.links.values.flatMap({ $0 }).first(where: { $0.id == linkID }) else { return }
        guard let provider = NativeSessionProvider(rawValue: link.provider.rawValue) else {
            nativeWorkspace.report(error: NativeWorkspaceError.unsupportedProvider)
            return
        }
        let snapshot = nativeWorkspace.snapshots[linkID]
        let cursor = loadMore ? snapshot?.nextCursor : nil
        if loadMore, cursor == nil { return }
        nativeWorkspace.beginTask(loadMore
            ? "Reading and saving more \(provider.displayName) text…"
            : "Checking complete \(provider.displayName) history…")
        do {
            try await nativeWorkspace.operations.run(
                title: loadMore ? "Read more native history" : "Refresh complete native history",
                provider: provider, referenceID: linkID.uuidString,
                dataAccess: "Explicitly linked native chat text",
                dataDestination: "Local history snapshot; no model or native-session changes",
                kind: .sourceRefresh) {
                let reader = self.nativeWorkspace.makeReader(for: provider)
                if loadMore {
                    self.nativeWorkspace.operations.updateProgress(stage: "Reading next text page")
                    let page = try await reader.readSession(id: link.externalID, directory: snapshot?.directory, cursor: cursor)
                    try Task.checkCancellation()
                    try stores.mergeWorkspaceNativePage(linkID: linkID, page: page, requestCursor: cursor)
                    self.nativeWorkspace.savedLimits[linkID] = self.savedNativeLimit(linkID) + NativeWorkspaceModel.savedPageSize
                } else {
                    let operations = self.nativeWorkspace.operations
                    let pages = try await NativeHistoryRefresh.fetch(reader: reader, id: link.externalID,
                        directory: snapshot?.directory) { count in
                        await operations.updateProgress(stage: "Checking complete history · \(count) pages read", completed: count)
                    }
                    try Task.checkCancellation()
                    operations.updateProgress(stage: "Saving verified history atomically", completed: pages.count)
                    try stores.refreshWorkspaceNativeSession(linkID: linkID, pages: pages,
                        expectedLastSyncedAt: snapshot?.lastSyncedAt)
                }
                do { try self.refreshNativeSnapshot(id: linkID) }
                catch {
                    self.reportSavedNativeHistoryFailure()
                    self.nativeWorkspace.endTask("Text was saved, but this view could not reload. Reopen the chat; no provider retry is needed.")
                    return
                }
                self.refreshWorkspaces()
                self.nativeWorkspace.endTask(loadMore ? "Next text page saved locally." : "Complete available history checked and saved locally.")
            }
        } catch { nativeWorkspace.report(error: error) }
    }

    private func savedNativeLimit(_ linkID: UUID) -> Int {
        max(nativeWorkspace.savedLimits[linkID] ?? 0, NativeWorkspaceModel.savedPageSize)
    }

    private func refreshNativeSnapshot(id linkID: UUID) throws {
        guard let stores else { return }
        let limit = savedNativeLimit(linkID)
        nativeWorkspace.savedLimits[linkID] = limit
        let snapshot = try stores.workspaceNativeSnapshot(linkID: linkID)
        let count = try stores.workspaceNativeMessageCount(linkID: linkID)
        var loaded: [WorkspaceNativeMessage] = []
        while loaded.count < limit {
            let page = try stores.workspaceNativeMessages(linkID: linkID, offset: loaded.count,
                limit: min(NativeWorkspaceModel.savedPageSize, limit - loaded.count))
            if page.isEmpty { break }
            loaded += page
        }
        nativeWorkspace.snapshots[linkID] = snapshot
        nativeWorkspace.savedCounts[linkID] = count
        nativeWorkspace.savedMessages[linkID] = loaded
    }

    private func reportSavedNativeHistoryFailure() {
        workspaceMessage = "Saved native history could not be displayed. The stored text has not been deleted."
        activityReporter?.problem(title: "Saved native history unavailable",
            outcome: "Saved history could not be displayed. Stored text is retained; no provider request was retried.")
    }
}
