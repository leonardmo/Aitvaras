import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore

func removeWorkspaceCodexNativeMigrationForTest(_ db: Database) throws {
    try db.execute(sql: "DROP TRIGGER IF EXISTS workspaceCodexNativeOperationImmutable")
    for table in ["workspaceCodexNativeOperationEvent", "workspaceCodexNativeItem", "workspaceCodexNativeProjection", "workspaceCodexNativeObservation", "workspaceCodexNativeOperation"] {
        try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
    }
    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v23-workspace-codex-native'")
}

@Suite struct WorkspaceCodexNativeStoreTests {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    private func setup(_ stores: Stores, profile: String = "synthetic-profile") throws
        -> (WorkspaceProject, WorkspaceChat, WorkspaceCodexProjectLink, WorkspaceCodexChatLink) {
        let project = try stores.createWorkspaceProject(title: "Synthetic native project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic native chat")
        let snapshot = NativeProjectSnapshot(identity: .init(provider: .codex, hostID: "synthetic-host",
            profileNamespace: profile, externalID: "synthetic-native-project"), name: "Synthetic native",
            roots: [.init(path: "/synthetic/native")])
        let projectLink = try stores.linkWorkspaceCodexProject(projectID: project.id, snapshot: snapshot,
            reviewedRoots: [.init(path: "/synthetic/native", canonicalPath: "/synthetic/native",
                filesystemIdentity: "synthetic-device:1", availability: .available)], reviewed: true, now: time)
        let link = try stores.linkWorkspaceCodexChat(chatID: chat.id, projectLinkID: projectLink.id,
            nativeProjectIdentity: snapshot.identity, nativeThreadID: "synthetic-native-thread",
            workingDirectory: "/synthetic/native/worktree", expectedProjectRevision: projectLink.revision, reviewed: true, now: time)
        return (project, chat, projectLink, link)
    }

    private func snapshot(status: String = "idle", turnStatus: String? = nil, complete: Bool = true,
        projectID: String = "synthetic-native-project", cwd: String = "/synthetic/native/worktree",
        items: [CodexNativeItemSnapshot]? = nil) -> CodexNativeThreadSnapshot {
        let turns: [CodexNativeTurnSnapshot] = turnStatus.map {
            [.init(id: "synthetic-turn", status: $0, order: 0, raw: ["status": .string($0)])]
        } ?? []
        return .init(id: "synthetic-native-thread", name: "Synthetic chat", projectID: projectID, cwd: cwd,
            status: status, raw: ["syntheticUnknownThreadField": true], turns: turns, items: items ?? [],
            complete: complete, observedAt: time)
    }

    private func item(_ id: String, turn: String = "synthetic-turn", kind: String = "agentMessage", order: Int,
        text: String = "Synthetic answer") -> CodexNativeItemSnapshot {
        let content: CodexJSONValue = kind == "userMessage"
            ? ["id": .string(id), "type": .string(kind), "content": [["type": "text", "text": .string(text)]]]
            : ["id": .string(id), "type": .string(kind), "text": .string(text), "unknownField": ["keep": true]]
        return .init(id: id, turnID: turn, kind: kind, order: order, raw: ["item": content, "unknownEntryField": "retained"])
    }

    private func project(_ stores: Stores, projectLink: WorkspaceCodexProjectLink, link: WorkspaceCodexChatLink,
        snapshot: CodexNativeThreadSnapshot? = nil, revision: Int? = nil) throws -> WorkspaceCodexNativeProjection {
        try stores.replaceWorkspaceCodexNativeProjection(chatLinkID: link.id, snapshot: snapshot ?? self.snapshot(),
            expectedProjectRevision: projectLink.revision, expectedChatRevision: link.revision,
            expectedProjectionRevision: revision, now: time)
    }

    private func grant(_ stores: Stores, projectLink: WorkspaceCodexProjectLink, link: WorkspaceCodexChatLink) throws {
        _ = try stores.authorizeWorkspaceCodexNativeTools(chatLinkID: link.id,
            expectedProjectRevision: projectLink.revision, expectedChatRevision: link.revision,
            effectiveConfigurationFingerprint: "synthetic-exact-settings", reviewedPolicySummary: "Synthetic reviewed native settings",
            reviewed: true, now: time)
    }

    private func request(_ stores: Stores, projectLink: WorkspaceCodexProjectLink, link: WorkspaceCodexChatLink,
        projection: WorkspaceCodexNativeProjection) throws -> WorkspaceCodexNativeOperation {
        try stores.requestWorkspaceCodexNativeOperation(chatLinkID: link.id, kind: .send,
            userMessage: "Synthetic private user message", expectedProjectRevision: projectLink.revision,
            expectedChatRevision: link.revision, expectedProjectionRevision: projection.revision,
            effectiveConfigurationFingerprint: "synthetic-exact-settings", now: time)
    }

    @Test func completeRefreshIsCanonicalAndPreservesOtherSourcesAndHistoricalEvidence() throws {
        let stores = try inMemoryStores()
        let (localProject, chat, projectLink, link) = try setup(stores)
        let local = StoredMessage(conversationID: chat.localConversationID, role: "user", content: "Synthetic local text")
        try stores.appendMessage(local)
        let imported = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .codex,
            externalID: "synthetic-import-only", displayName: "Synthetic separate import"))
        let review = try stores.workspacePolicyReview(projectID: localProject.id)
        let policy = try stores.reviewWorkspacePolicy(projectID: localProject.id, allowedProviders: [.codex], expectedRevision: review.revision)
        let packet = try stores.workspaceContextPacket(chatID: chat.id)
        let owned = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-isolated-model", effort: nil,
            expectedPolicyRevision: policy.revision, reviewedContext: packet.promptText)
        _ = try stores.bindWorkspaceFrontierSession(id: owned.id, externalID: "synthetic-separate-owned-thread")
        var isolatedTurn = try stores.beginWorkspaceFrontierTurn(sessionID: owned.id, prompt: "Synthetic isolated input")
        isolatedTurn.state = .running; isolatedTurn.providerTurnID = "synthetic-isolated-turn"
        try stores.saveWorkspaceFrontierTurn(isolatedTurn)
        isolatedTurn.state = .completed; isolatedTurn.outputText = "Synthetic isolated output"; isolatedTurn.endedAt = .now
        try stores.saveWorkspaceFrontierTurn(isolatedTurn)
        let savedIsolatedTurn = try stores.workspaceFrontierTurn(id: isolatedTurn.id)
        let savedIsolatedSessions = try stores.workspaceFrontierSessions(chatID: chat.id)
        let original = snapshot(turnStatus: "completed", items: [
            item("synthetic-answer", order: 2), item("synthetic-tool", kind: "futureUnknownTool", order: 1),
            item("synthetic-user", kind: "userMessage", order: 0, text: "Synthetic native question")])
        let first = try project(stores, projectLink: projectLink, link: link, snapshot: original)
        #expect(first.snapshot.items.map(\.id) == ["synthetic-user", "synthetic-tool", "synthetic-answer"])
        let items = try stores.workspaceCodexNativeItems(chatID: chat.id)
        #expect(items.map(\.nativeItemID) == first.snapshot.items.map(\.id))
        #expect(items.map(\.role) == ["user", nil, "assistant"])
        #expect(items.first?.text == "Synthetic native question")
        #expect(items.last?.rawJSON.contains("unknownEntryField") == true)
        let second = try project(stores, projectLink: projectLink, link: link,
            snapshot: snapshot(turnStatus: "completed", items: [item("synthetic-answer", order: 0, text: "Synthetic corrected answer")]),
            revision: first.revision)
        #expect(second.revision == 2)
        #expect(try stores.workspaceCodexNativeItems(chatID: chat.id).map(\.text) == ["Synthetic corrected answer"])
        #expect(try stores.workspaceCodexNativeItems(chatID: chat.id).first?.timestamp == items.last?.timestamp)
        let observations = try stores.workspaceCodexNativeObservations(chatLinkID: link.id)
        #expect(observations.map(\.projectionRevision) == [2, 1])
        #expect(observations.last?.snapshot.items.count == 3)
        #expect(try stores.messages(in: chat.localConversationID).map(\.id) == [local.id])
        #expect(try stores.workspaceSessionLinks(chatID: chat.id).map(\.id) == [imported.id])
        #expect(try stores.workspaceFrontierSessions(chatID: chat.id) == savedIsolatedSessions)
        #expect(try stores.workspaceFrontierTurn(id: isolatedTurn.id) == savedIsolatedTurn)
    }

    @Test func incompleteMalformedIdentityAndStaleRefreshesCannotEraseProjection() throws {
        let stores = try inMemoryStores()
        let (_, chat, projectLink, link) = try setup(stores)
        let first = try project(stores, projectLink: projectLink, link: link,
            snapshot: snapshot(turnStatus: "completed", items: [item("synthetic-answer", order: 0)]))
        #expect(throws: WorkspaceCodexNativeError.incompleteSnapshot) {
            try project(stores, projectLink: projectLink, link: link, snapshot: snapshot(complete: false), revision: first.revision)
        }
        #expect(throws: WorkspaceCodexNativeError.invalidValue) {
            try project(stores, projectLink: projectLink, link: link,
                snapshot: snapshot(turnStatus: "completed", items: [item("duplicate", order: 0), item("duplicate", order: 1)]),
                revision: first.revision)
        }
        #expect(throws: WorkspaceCodexNativeError.identityMismatch) {
            try project(stores, projectLink: projectLink, link: link, snapshot: snapshot(projectID: "synthetic-other-project"), revision: 1)
        }
        #expect(throws: WorkspaceCodexNativeError.identityMismatch) {
            try project(stores, projectLink: projectLink, link: link, snapshot: snapshot(cwd: "/synthetic/native/main"), revision: 1)
        }
        #expect(throws: WorkspaceCodexNativeError.staleRevision) {
            try project(stores, projectLink: projectLink, link: link, revision: nil)
        }
        #expect(try stores.workspaceCodexNativeProjection(chatLinkID: link.id) == first)
        #expect(try stores.workspaceCodexNativeItems(chatID: chat.id).count == 1)
        #expect(try stores.workspaceCodexNativeObservations(chatLinkID: link.id).count == 1)
    }

    @Test func typedUnknownAndPartialStatesNeverBecomeCompletedContextOrIdleAuthority() throws {
        let stores = try inMemoryStores()
        let (_, chat, projectLink, link) = try setup(stores)
        let projection = try project(stores, projectLink: projectLink, link: link,
            snapshot: snapshot(status: "futureState", turnStatus: "futureTurnState", items: [item("synthetic-partial", order: 0)]))
        #expect(projection.threadState == .unknown)
        #expect(try stores.workspaceCodexNativeItems(chatID: chat.id).first?.turnState == .unknown)
        #expect(try stores.workspaceCodexNativeItems(chatID: chat.id, completedOnly: true).isEmpty)
        try grant(stores, projectLink: projectLink, link: link)
        #expect(throws: WorkspaceCodexNativeError.busyNativeThread) { try request(stores, projectLink: projectLink, link: link, projection: projection) }
        let active = try project(stores, projectLink: projectLink, link: link,
            snapshot: snapshot(status: "idle", turnStatus: "inProgress"), revision: projection.revision)
        #expect(throws: WorkspaceCodexNativeError.busyNativeThread) { try request(stores, projectLink: projectLink, link: link, projection: active) }
    }

    @Test func hostProfileQualifiedCacheDoesNotAliasNativeIDs() throws {
        let stores = try inMemoryStores()
        let (_, chat1, project1, link1) = try setup(stores)
        let (_, chat2, project2, link2) = try setup(stores, profile: "synthetic-other-profile")
        _ = try project(stores, projectLink: project1, link: link1,
            snapshot: snapshot(turnStatus: "completed", items: [item("same-synthetic-id", order: 0, text: "Synthetic profile one")]))
        _ = try project(stores, projectLink: project2, link: link2,
            snapshot: snapshot(turnStatus: "completed", items: [item("same-synthetic-id", order: 0, text: "Synthetic profile two")]))
        #expect(try stores.workspaceCodexNativeItems(chatID: chat1.id).first?.text == "Synthetic profile one")
        #expect(try stores.workspaceCodexNativeItems(chatID: chat2.id).first?.text == "Synthetic profile two")
    }

    @Test func sendsRequireExactGrantAndRecheckRevisionsBeforeDelivery() throws {
        let stores = try inMemoryStores()
        let (_, _, projectLink, link) = try setup(stores)
        let projection = try project(stores, projectLink: projectLink, link: link)
        #expect(throws: WorkspaceCodexNativeError.reviewRequired) { try request(stores, projectLink: projectLink, link: link, projection: projection) }
        try grant(stores, projectLink: projectLink, link: link)
        #expect(throws: WorkspaceCodexNativeError.reviewRequired) {
            try stores.requestWorkspaceCodexNativeOperation(chatLinkID: link.id, kind: .send, userMessage: "Synthetic input",
                expectedProjectRevision: projectLink.revision, expectedChatRevision: link.revision,
                expectedProjectionRevision: projection.revision, effectiveConfigurationFingerprint: "synthetic-other-settings")
        }
        let requested = try request(stores, projectLink: projectLink, link: link, projection: projection)
        #expect(requested.state == .requested && requested.userMessage == "Synthetic private user message")
        let prepared = try stores.prepareWorkspaceCodexNativeOperation(id: requested.id, expectedRevision: requested.revision, now: time)
        _ = try project(stores, projectLink: projectLink, link: link, revision: projection.revision)
        #expect(throws: WorkspaceCodexNativeError.staleRevision) {
            try stores.beginWorkspaceCodexNativeDelivery(id: prepared.id, expectedRevision: prepared.revision)
        }
        #expect(try stores.workspaceCodexNativeOperation(id: requested.id)?.state == .prepared)
        #expect(throws: WorkspaceCodexNativeError.unresolvedOperation) {
            try request(stores, projectLink: projectLink, link: link,
                projection: #require(try stores.workspaceCodexNativeProjection(chatLinkID: link.id)))
        }
    }

    @Test func nativeSendDeliveryIsOnceAndBoundTurnReconcilesWithoutReplaying() throws {
        let stores = try inMemoryStores()
        let (_, _, projectLink, link) = try setup(stores)
        let projection = try project(stores, projectLink: projectLink, link: link)
        try grant(stores, projectLink: projectLink, link: link)
        let requested = try request(stores, projectLink: projectLink, link: link, projection: projection)
        let prepared = try stores.prepareWorkspaceCodexNativeOperation(id: requested.id, expectedRevision: 1, now: time)
        let delivering = try stores.beginWorkspaceCodexNativeDelivery(id: prepared.id, expectedRevision: prepared.revision, now: time)
        #expect(delivering.state == .deliveryUnknown)
        #expect(throws: WorkspaceCodexNativeError.invalidTransition) {
            try stores.beginWorkspaceCodexNativeDelivery(id: delivering.id, expectedRevision: delivering.revision)
        }
        let acknowledged = try stores.acknowledgeWorkspaceCodexNativeOperation(id: delivering.id,
            nativeTurnID: "synthetic-turn", expectedRevision: delivering.revision, now: time)
        #expect(throws: WorkspaceCodexNativeError.invalidTransition) {
            try stores.acknowledgeWorkspaceCodexNativeOperation(id: acknowledged.id,
                nativeTurnID: "synthetic-reassigned-turn", expectedRevision: acknowledged.revision)
        }
        #expect(throws: WorkspaceCodexNativeError.invalidTransition) {
            try stores.finishWorkspaceCodexNativeOperation(id: acknowledged.id, state: .failed, expectedRevision: acknowledged.revision)
        }
        #expect(try stores.reconcileUnfinishedWorkspaceCodexNativeOperations(now: time) == 1)
        let uncertain = try #require(try stores.workspaceCodexNativeOperation(id: requested.id))
        #expect(uncertain.state == .deliveryUnknown && uncertain.nativeTurnID == "synthetic-turn")
        _ = try project(stores, projectLink: projectLink, link: link,
            snapshot: snapshot(turnStatus: "completed"), revision: projection.revision)
        #expect(try stores.workspaceCodexNativeOperation(id: requested.id)?.state == .completed)
        #expect(try stores.workspaceCodexNativeOperationEvents(id: requested.id).map(\.state)
            == [.requested, .prepared, .deliveryUnknown, .acknowledged, .deliveryUnknown, .completed])
    }

    @Test func nativeHandoverStrippingRequiresExactRecordedTurnAndWire() throws {
        let stores = try inMemoryStores()
        let (_, chat, projectLink, link) = try setup(stores)
        let pasted = "\(WorkspaceHandoverText.header)]\nPasted example\n\(WorkspaceHandoverText.footer)\nKeep all of this."
        let first = try project(stores, projectLink: projectLink, link: link,
            snapshot: snapshot(turnStatus: "completed", items: [item("synthetic-user", kind: "userMessage", order: 0, text: pasted)]))
        #expect(try stores.workspaceCodexNativeTimeline(chatID: chat.id).first?.text == pasted)

        try grant(stores, projectLink: projectLink, link: link)
        let requested = try request(stores, projectLink: projectLink, link: link, projection: first)
        let prepared = try stores.prepareWorkspaceCodexNativeOperation(id: requested.id, expectedRevision: requested.revision, now: time)
        let delivering = try stores.beginWorkspaceCodexNativeDelivery(id: prepared.id, expectedRevision: prepared.revision, now: time)
        _ = try stores.acknowledgeWorkspaceCodexNativeOperation(id: delivering.id,
            nativeTurnID: "synthetic-turn", expectedRevision: delivering.revision, now: time)
        let block = "\(WorkspaceHandoverText.header)]\n[user · Local] \(pasted)\n\(WorkspaceHandoverText.footer)"
        let plan = WorkspaceHandoverPlan(threadKey: WorkspaceThreadKey.codexNative(link.id), text: block,
            entryCount: 1, omittedCount: 0, providers: ["local"], throughTimestamp: time, throughEntryID: "synthetic-local-entry")
        try stores.recordWorkspaceHandover(plan, chatID: chat.id, turnID: requested.id, anchor: time)
        let wire = WorkspaceHandoverText.wire(handover: block, message: requested.userMessage!)
        let second = try project(stores, projectLink: projectLink, link: link,
            snapshot: snapshot(turnStatus: "completed", items: [item("synthetic-user", kind: "userMessage", order: 0, text: wire)]),
            revision: first.revision)
        #expect(try stores.workspaceCodexNativeTimeline(chatID: chat.id).first?.text == requested.userMessage)
        let otherTurn = CodexNativeThreadSnapshot(id: "synthetic-native-thread", name: "Synthetic chat",
            projectID: "synthetic-native-project", cwd: "/synthetic/native/worktree", status: "idle", raw: [:],
            turns: [.init(id: "synthetic-unattributed-turn", status: "completed", order: 0, raw: [:])],
            items: [item("synthetic-other-user", turn: "synthetic-unattributed-turn", kind: "userMessage", order: 0, text: wire)],
            complete: true, observedAt: time)
        let third = try project(stores, projectLink: projectLink, link: link,
            snapshot: otherTurn, revision: second.revision)
        #expect(try stores.workspaceCodexNativeTimeline(chatID: chat.id).first?.text == wire)
        // A desktop edit invalidates the exact envelope match; no text is hidden.
        _ = try project(stores, projectLink: projectLink, link: link,
            snapshot: snapshot(turnStatus: "completed", items: [item("synthetic-user", kind: "userMessage", order: 0, text: wire + " edited")]),
            revision: third.revision)
        #expect(try stores.workspaceCodexNativeTimeline(chatID: chat.id).first?.text == wire + " edited")
    }

    @Test func nativeTimestampCorrectionDoesNotSkipMessagesAfterTheExactWatermark() throws {
        let stores = try inMemoryStores()
        let (_, chat, projectLink, link) = try setup(stores)
        let first = try project(stores, projectLink: projectLink, link: link,
            snapshot: snapshot(turnStatus: "completed", items: [item("synthetic-first", order: 0, text: "Already shared")]))
        let target = "codex:synthetic-other-thread"
        let prior = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: target))
        try stores.recordWorkspaceHandover(prior, chatID: chat.id, turnID: UUID(), anchor: time)
        func dated(_ id: String, order: Int, text: String, timestamp: Int) -> CodexNativeItemSnapshot {
            .init(id: id, turnID: "synthetic-turn", kind: "agentMessage", order: order,
                raw: ["item": ["type": "agentMessage", "text": .string(text)], "createdAt": .int(timestamp)])
        }
        _ = try project(stores, projectLink: projectLink, link: link,
            snapshot: snapshot(turnStatus: "completed", items: [
                dated("synthetic-first", order: 0, text: "Already shared", timestamp: 10),
                dated("synthetic-second", order: 1, text: "Newly completed", timestamp: 20)]), revision: first.revision)
        let next = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: target))
        #expect(next.entryCount == 1 && next.text.contains("Newly completed") && !next.text.contains("Already shared"))
    }

    @Test func stopIntentIsNotProviderCompletion() throws {
        let stores = try inMemoryStores()
        let (_, _, projectLink, link) = try setup(stores)
        let projection = try project(stores, projectLink: projectLink, link: link)
        try grant(stores, projectLink: projectLink, link: link)
        let first = try request(stores, projectLink: projectLink, link: link, projection: projection)
        let cancelledBeforeDelivery = try stores.requestWorkspaceCodexNativeCancellation(id: first.id, expectedRevision: first.revision, now: time)
        #expect(cancelledBeforeDelivery.state == .cancelled)
        let second = try request(stores, projectLink: projectLink, link: link, projection: projection)
        let prepared = try stores.prepareWorkspaceCodexNativeOperation(id: second.id, expectedRevision: second.revision, now: time)
        let delivering = try stores.beginWorkspaceCodexNativeDelivery(id: second.id, expectedRevision: prepared.revision, now: time)
        let stopped = try stores.requestWorkspaceCodexNativeCancellation(id: second.id, expectedRevision: delivering.revision, now: time)
        #expect(stopped.state == .deliveryUnknown && stopped.endedAt == nil && stopped.cancellationRequestedAt != nil)
        #expect(throws: WorkspaceCodexNativeError.invalidTransition) {
            try stores.finishWorkspaceCodexNativeOperation(id: stopped.id, state: .cancelled, expectedRevision: stopped.revision)
        }
        #expect(throws: WorkspaceCodexNativeError.invalidTransition) {
            try stores.finishWorkspaceCodexNativeOperation(id: stopped.id, state: .completed,
                expectedRevision: stopped.revision, providerConfirmed: true)
        }
        let acknowledged = try stores.acknowledgeWorkspaceCodexNativeOperation(id: stopped.id,
            nativeTurnID: "synthetic-turn", expectedRevision: stopped.revision, now: time)
        let actualCompleted = try stores.finishWorkspaceCodexNativeOperation(id: stopped.id, state: .completed,
            expectedRevision: acknowledged.revision, providerConfirmed: true, now: time)
        #expect(actualCompleted.state == .completed)
    }

    @Test func startupReconciliationIsDurableUnknownAndNeverReplaysEvenUnsentIntents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-native-journal-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.sqlite")
        let operationID: UUID, chatLinkID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let (_, _, projectLink, link) = try setup(stores)
            let projection = try project(stores, projectLink: projectLink, link: link)
            try grant(stores, projectLink: projectLink, link: link)
            let operation = try request(stores, projectLink: projectLink, link: link, projection: projection)
            operationID = operation.id; chatLinkID = link.id
        }
        let reopened = Stores(db: try AitvarasDatabase(url: url))
        #expect(try reopened.workspaceCodexNativeOperation(id: operationID)?.state == .requested)
        #expect(try reopened.reconcileUnfinishedWorkspaceCodexNativeOperations(now: time) == 1)
        #expect(try reopened.reconcileUnfinishedWorkspaceCodexNativeOperations(now: time) == 0)
        let saved = try #require(try reopened.workspaceCodexNativeOperation(id: operationID))
        #expect(saved.state == .deliveryUnknown && saved.userMessage == "Synthetic private user message" && saved.nativeTurnID == nil)
        #expect(try reopened.workspaceCodexNativeOperations(chatLinkID: chatLinkID, unresolvedOnly: true).count == 1)
        #expect(try reopened.workspaceCodexNativeOperationEvents(id: operationID).map(\.state) == [.requested, .deliveryUnknown])
    }

    @Test func unlinkPreservesHistoryAndJournalAndCannotBypassUncertainDelivery() throws {
        let stores = try inMemoryStores()
        let (_, chat, projectLink, link) = try setup(stores)
        let projection = try project(stores, projectLink: projectLink, link: link)
        try grant(stores, projectLink: projectLink, link: link)
        let requested = try request(stores, projectLink: projectLink, link: link, projection: projection)
        _ = try stores.reconcileUnfinishedWorkspaceCodexNativeOperations(now: time)
        try stores.unlinkWorkspaceCodexChat(linkID: link.id, expectedRevision: link.revision)
        #expect(try stores.workspaceCodexNativeProjection(chatLinkID: link.id) == nil)
        #expect(try stores.workspaceCodexNativeObservations(chatLinkID: link.id).count == 1)
        #expect(try stores.workspaceCodexNativeOperation(id: requested.id)?.state == .deliveryUnknown)
        let newLink = try stores.linkWorkspaceCodexChat(chatID: chat.id, projectLinkID: projectLink.id,
            nativeProjectIdentity: projectLink.approvedSnapshot.identity, nativeThreadID: link.externalID,
            workingDirectory: link.workingDirectory, expectedProjectRevision: projectLink.revision, reviewed: true)
        let newProjection = try project(stores, projectLink: projectLink, link: newLink)
        try grant(stores, projectLink: projectLink, link: newLink)
        #expect(throws: WorkspaceCodexNativeError.unresolvedOperation) {
            try request(stores, projectLink: projectLink, link: newLink, projection: newProjection)
        }
    }

    @Test func additiveMigrationPreservesPriorLinksMessagesAndImportsWithoutAdoption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-native-migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.sqlite")
        let chatID: UUID, linkID: UUID, message: StoredMessage
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let (_, chat, _, link) = try setup(stores)
            chatID = chat.id; linkID = link.id
            message = StoredMessage(conversationID: chat.localConversationID, role: "user", content: "Synthetic preserved input")
            try stores.appendMessage(message)
            _ = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .codex,
                externalID: "synthetic-separate-import", displayName: "Synthetic import"))
            try stores.db.queue.write { dbc in
                try dbc.execute(sql: "DROP TRIGGER workspaceCodexNativeOperationImmutable")
                for table in ["workspaceCodexNativeOperationEvent", "workspaceCodexNativeOperation", "workspaceCodexNativeItem",
                    "workspaceCodexNativeObservation", "workspaceCodexNativeProjection"] {
                    try dbc.execute(sql: "DROP TABLE \(table)")
                }
                try dbc.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v23-workspace-codex-native'")
            }
        }
        let upgraded = Stores(db: try AitvarasDatabase(url: url))
        #expect(try upgraded.workspaceCodexChatLink(chatID: chatID)?.id == linkID)
        #expect(try upgraded.messages(in: message.conversationID).map(\.id) == [message.id])
        #expect(try upgraded.workspaceSessionLinks(chatID: chatID).count == 1)
        #expect(try upgraded.workspaceCodexNativeProjection(chatLinkID: linkID) == nil)
        #expect(try upgraded.workspaceCodexNativeOperations(chatLinkID: linkID).isEmpty)
        #expect(try upgraded.db.queue.read { try Int.fetchOne($0,
            sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v23-workspace-codex-native'") } == 1)
    }
}
