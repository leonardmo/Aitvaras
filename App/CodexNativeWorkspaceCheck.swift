import Foundation
import AitvarasCore
import AitvarasStore
import AitvarasConnectors

/// Entirely synthetic App-model contract check. No CLI, provider, account,
/// production database, or real project is opened or changed.
@MainActor
enum CodexNativeWorkspaceCheck {
    enum Failure: Error { case assertion(String), timedOut(String) }

    static func run() async throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-native-workspace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("primary")
        let secondary = directory.appendingPathComponent("secondary")
        let worktree = primary.appendingPathComponent("worktree")
        for url in [primary, secondary, worktree] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let roots = [secondary, primary].map { $0.resolvingSymlinksInPath().path }
        let cwd = worktree.resolvingSymlinksInPath().path
        let stores = Stores(db: try AitvarasDatabase(url: nil))
        let reporter = ActivityReporter(stores: stores)
        let project = try stores.createWorkspaceProject(title: "Synthetic native project", instructions: "LOCAL_NATIVE_INSTRUCTIONS_CANARY")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic native chat", kind: .primary)
        let local = StoredMessage(conversationID: chat.localConversationID, role: "user", content: "LOCAL_NATIVE_PRIVATE_CANARY")
        try stores.appendMessage(local)
        let imported = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .codex,
            externalID: "synthetic-import-only", displayName: "Synthetic separate historical import"))
        let nativeProject = NativeProjectSnapshot(identity: .init(provider: .codex, hostID: "local",
            profileNamespace: "synthetic-profile", externalID: SyntheticNativeWorkspaceTransport.projectID),
            name: "Synthetic native project", roots: roots.map { .init(path: $0) })
        _ = try stores.linkWorkspaceCodexProject(projectID: project.id, snapshot: nativeProject,
            reviewedRoots: Stores.workspaceCodexRootReviews(for: nativeProject), reviewed: true)
        let fake = SyntheticNativeWorkspaceTransport(roots: roots, cwd: cwd)
        let model = CodexNativeWorkspaceModel()
        try model.configure(stores: stores, reporter: reporter, transport: fake, profileNamespace: "synthetic-profile")
        model.load(chatID: chat.id)
        try require(await fake.callCount == 0, "Opening a local chat must not connect or send")
        await model.connect()
        try require(model.isConnected && model.authenticated && model.models.map(\.id) == ["synthetic-model"], "Synthetic native connection and catalog")
        await model.browseChats(projectID: project.id)
        try require(model.threadChoices.map(\.id) == [SyntheticNativeWorkspaceTransport.threadID, "synthetic-other-thread"], "Paged native project chat listing")
        await model.reviewChat(threadID: SyntheticNativeWorkspaceTransport.threadID)
        try require(model.linkReview?.canContinue == true && model.linkReview?.workingDirectory == cwd, "Explicit non-first-root working directory review")
        try require(await fake.startCount == 0, "Browsing and review must never send")
        try require(await model.linkReviewedChat(chatID: chat.id), "Explicit reviewed native chat linking")
        let link = try needed(try stores.workspaceCodexChatLink(chatID: chat.id), "Saved native relationship")
        try require(link.externalID == SyntheticNativeWorkspaceTransport.threadID && link.workingDirectory == cwd, "Canonical native identity retained")
        try require(try stores.workspaceCodexNativeAuthorization(chatLinkID: link.id) != nil, "Exact native configuration consent saved")
        try require(try stores.workspaceCodexNativeItems(chatID: chat.id).contains(where: { $0.kind == "syntheticFutureTool" }), "Unknown native variants retained")
        try require(try stores.workspaceFrontierSessions(chatID: chat.id).isEmpty, "No isolated owned-session adoption")

        // Streaming is visible before completion; approvals are never answered
        // until the synthetic user explicitly responds to the exact request.
        let firstPrompt = "SYNTHETIC_NATIVE_PROMPT_CANARY"
        let first = Task { @MainActor in await model.sendFromComposer(prompt: firstPrompt, chatID: chat.id, modelID: "synthetic-model", effort: "medium") }
        try await waitUntil("First native turn acknowledged") { await fake.startCount == 1 && model.nativeWorkActive }
        let firstTurn = await fake.latestTurnID
        await fake.emitText("SYNTHETIC_NATIVE_REPLY_", turnID: firstTurn)
        await fake.emitText("CANARY", turnID: firstTurn)
        await fake.emit(.notification(method: "thread/tokenUsage/updated", params: ["threadId": .string(link.externalID),
            "tokenUsage": ["last": ["totalTokens": 120], "modelContextWindow": 1000]]))
        await fake.emit(.notification(method: "account/rateLimits/updated", params: ["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 300]]]))
        try await waitUntil("Live deltas and usage") {
            model.liveEntries.last?.text == "SYNTHETIC_NATIVE_REPLY_CANARY" && model.contextUsedTokens == 120
                && model.usageWindows.first?.usedPercent == 25
        }
        try require(model.contextLimitTokens == 1000 && model.usageWindows.first?.usedPercent == 25, "Native usage is surfaced")
        try require(!(try stores.workspaceChatHistoryText(chatID: chat.id)).contains("SYNTHETIC_NATIVE_REPLY_CANARY"), "Partial output is not completed history")
        await fake.emit(.serverRequest(.init(id: "synthetic-wrong-thread-approval", method: "item/commandExecution/requestApproval",
            threadID: "synthetic-other-thread", turnID: firstTurn, itemID: nil, params: ["command": "synthetic command"])))
        await fake.emit(.serverRequest(.init(id: "synthetic-command-approval", method: "item/commandExecution/requestApproval",
            threadID: link.externalID, turnID: firstTurn, itemID: "synthetic-command-item", params: ["command": "synthetic reviewed command", "cwd": .string(cwd)])))
        try await waitUntil("Command approval displayed") { model.pendingApprovals.count == 1 }
        try require(await fake.responseCount == 0, "No automatic approval or unrelated-thread request")
        let commandApproval = try needed(model.pendingApprovals.first, "Command approval")
        try require(commandApproval.canAllow && commandApproval.detail.contains("synthetic reviewed command"), "Command preview is shown before approval")
        await model.respond(approvalID: commandApproval.id, allow: true)
        try require(await fake.lastResponse == ["decision": "accept"], "Exact explicit command approval")
        await fake.emit(.serverRequest(.init(id: "synthetic-incomplete-approval", method: "item/commandExecution/requestApproval",
            threadID: link.externalID, turnID: firstTurn, itemID: nil, params: ["reason": "Synthetic incomplete request"])))
        try await waitUntil("Incomplete request displayed") { model.pendingApprovals.count == 1 }
        let incomplete = try needed(model.pendingApprovals.first, "Incomplete approval")
        try require(!incomplete.canAllow, "Incomplete native request cannot be accepted")
        await model.respond(approvalID: incomplete.id, allow: true)
        try require(await fake.responseCount == 1, "Incomplete native request has no implicit acceptance")
        await model.respond(approvalID: incomplete.id, allow: false)
        try require(await fake.lastResponse == ["decision": "decline"], "Explicit decline stays available")
        await fake.emit(.serverRequest(.init(id: "synthetic-user-input", method: "item/tool/requestUserInput",
            threadID: link.externalID, turnID: firstTurn, itemID: "synthetic-question-item", params: ["questions": [
                ["id": "synthetic-question", "question": "Choose a synthetic option", "options": [["label": "Synthetic option"]]]]])))
        try await waitUntil("Native question displayed") { model.pendingApprovals.first?.questions.count == 1 }
        let question = try needed(model.pendingApprovals.first, "Native question")
        await model.respond(approvalID: question.id, allow: true, answers: ["synthetic-question": "Synthetic option"])
        try require(await fake.lastResponse == ["answers": ["synthetic-question": ["answers": ["Synthetic option"]]]], "Explicit native user-input answer")
        await fake.complete(turnID: firstTurn)
        try await waitUntil("First turn completed") { !model.isBusy }
        try require(await first.value, "First explicit input durably recorded")
        let firstOperation = try needed(try stores.workspaceCodexNativeOperations(chatLinkID: link.id).last, "First journal entry")
        try require(firstOperation.state == .completed && firstOperation.nativeTurnID == firstTurn, "Confirmed native completion journalled")
        try require(await fake.lastPrompt == firstPrompt, "No automatic local instructions or cross-provider history backfill")
        try require(await fake.lastClientUserMessageID == firstOperation.id.uuidString, "Durable operation correlation sent with native input")
        try require(model.liveEntries.isEmpty && (try stores.workspaceCodexNativeItems(chatID: chat.id)).contains(where: { $0.text == "SYNTHETIC_NATIVE_REPLY_CANARY" }), "Streaming reconciles into canonical native IDs")

        // A changed effective configuration is only an observation until Save.
        await fake.setNetworkAccess(true)
        await model.refreshHistory()
        let denied = await model.sendFromComposer(prompt: "Synthetic unreviewed setting must not send", chatID: chat.id, modelID: "synthetic-model", effort: nil)
        let deniedStarts = await fake.startCount
        try require(!denied && deniedStarts == 1, "Changed native configuration requires exact renewed consent")
        try require(await model.linkReviewedChat(chatID: chat.id), "Explicit renewed configuration review")
        try require(try stores.workspaceCodexChatLink(chatID: chat.id)?.id == link.id, "Permission review does not create a second native identity")

        // Stop while turn/start is suspended must bind the returned ID once,
        // retain the stop intent and request native interruption, not completion.
        await fake.setMode(.holdStart)
        let stopping = Task { @MainActor in await model.sendFromComposer(prompt: "Synthetic stop during turn start", chatID: chat.id, modelID: "synthetic-model", effort: nil) }
        try await waitUntil("Suspended native start") {
            let count = await fake.startCount
            let held = await fake.isStartHeld
            return count == 2 && held
        }
        await model.stop()
        let stopIntent = try needed(try stores.workspaceCodexNativeOperations(chatLinkID: link.id).last, "Stop intent journal")
        try require(stopIntent.state == .deliveryUnknown && stopIntent.cancellationRequestedAt != nil && stopIntent.nativeTurnID == nil, "Stop before native acknowledgement stays uncertain")
        await fake.releaseStart()
        try await waitUntil("Stopped native turn terminal") { !model.isBusy }
        _ = await stopping.value
        let stopped = try needed(try stores.workspaceCodexNativeOperations(chatLinkID: link.id).last, "Stopped native journal entry")
        try require([.interrupted, .cancelled].contains(stopped.state) && stopped.nativeTurnID != nil && stopped.cancellationRequestedAt != nil, "Native interruption confirms stop without false completion")
        let stoppedCounts = await fake.counters()
        try require(stoppedCounts.interrupts == 1 && stoppedCounts.starts == 2, "Stop race never resends input")

        // A disconnected controller is not completed native work. Reconnection
        // observes the same identity and cannot automatically replay any input.
        await fake.setMode(.manual)
        let disconnected = Task { @MainActor in await model.sendFromComposer(prompt: "Synthetic disconnect after acknowledgement", chatID: chat.id, modelID: "synthetic-model", effort: nil) }
        try await waitUntil("Disconnect turn acknowledged") {
            guard await fake.startCount == 3 else { return false }
            return try stores.workspaceCodexNativeOperations(chatLinkID: link.id).last?.state == .acknowledged
        }
        let disconnectedTurn = await fake.latestTurnID
        await fake.emitText("Synthetic partial disconnected answer", turnID: disconnectedTurn)
        await fake.emitDisconnect()
        try await waitUntil("Controller disconnected") { !model.isBusy && !model.isConnected }
        _ = await disconnected.value
        let unresolved = try needed(try stores.workspaceCodexNativeOperations(chatLinkID: link.id).last, "Unresolved disconnected journal entry")
        try require(!unresolved.state.isTerminal && unresolved.endedAt == nil, "Disconnect never becomes terminal completion")
        await model.connect()
        await model.refreshHistory()
        let reconnectStarts = await fake.startCount
        try require(model.nativeWorkActive && reconnectStarts == 3, "Reconnect only observes ongoing native work")
        _ = await model.sendFromComposer(prompt: "Synthetic attempted input while native work active", chatID: chat.id, modelID: "synthetic-model", effort: nil)
        try require(await fake.startCount == 3, "Observed busy native work blocks new input")
        await fake.complete(turnID: disconnectedTurn)
        try await waitUntil("External completion reconciled after reconnect") {
            let state = try stores.workspaceCodexNativeOperations(chatLinkID: link.id).last?.state
            return !model.isBusy && state == .completed
        }
        try require(await fake.startCount == 3, "Native outcome reconciliation has no prompt replay")

        // Delivery can succeed while its response is lost. Without a returned
        // native turn ID, even an idle refresh must not manufacture an outcome.
        await fake.setMode(.loseStartResponse)
        _ = await model.sendFromComposer(prompt: "Synthetic accepted input with lost acknowledgement", chatID: chat.id, modelID: "synthetic-model", effort: nil)
        let unknown = try needed(try stores.workspaceCodexNativeOperations(chatLinkID: link.id).last, "Unacknowledged journal entry")
        try require(unknown.state == .deliveryUnknown && unknown.nativeTurnID == nil, "Lost acknowledgement stays durably unknown")
        let unknownTurn = await fake.latestTurnID
        await fake.complete(turnID: unknownTurn)
        await model.connect()
        await model.refreshHistory()
        _ = await model.sendFromComposer(prompt: "Synthetic uncertain input must never replay", chatID: chat.id, modelID: "synthetic-model", effort: nil)
        try require(await fake.startCount == 4, "Unknown native delivery blocks further automatic or manual continuation")
        try require(try stores.workspaceCodexNativeOperation(id: unknown.id)?.state == .deliveryUnknown, "Text similarity is not native delivery evidence")

        // A previous-profile relationship must not issue even a history resume
        // against the current profile where native IDs may happen to collide.
        let wrongFake = SyntheticNativeWorkspaceTransport(roots: roots, cwd: cwd)
        let wrongProfile = CodexNativeWorkspaceModel()
        try wrongProfile.configure(stores: stores, reporter: reporter, transport: wrongFake, profileNamespace: "synthetic-different-profile")
        wrongProfile.load(chatID: chat.id)
        await wrongProfile.browseChats(projectID: project.id)
        await wrongProfile.refreshHistory()
        _ = await wrongProfile.sendFromComposer(prompt: "Synthetic mismatched profile must not send", chatID: chat.id, modelID: "synthetic-model", effort: nil)
        let wrongCounts = await wrongFake.counters()
        try require(wrongCounts.resumes == 0 && wrongCounts.snapshots == 0 && wrongCounts.starts == 0, "Profile mismatch blocks all thread reads and execution")
        try require(try stores.messages(in: chat.localConversationID).map(\.id) == [local.id], "Local messages survive native reconciliation")
        try require(try stores.workspaceSessionLinks(chatID: chat.id).map(\.id) == [imported.id], "Imported history remains a separate read-only source")
        try require(try stores.workspaceFrontierSessions(chatID: chat.id).isEmpty, "Native sends never populate isolated owned registry")
        let activity = String(decoding: try JSONEncoder().encode(stores.activityRuns(limit: 200)), as: UTF8.self)
        for canary in [firstPrompt, "SYNTHETIC_NATIVE_REPLY_CANARY", "LOCAL_NATIVE_PRIVATE_CANARY", "LOCAL_NATIVE_INSTRUCTIONS_CANARY"] {
            try require(!activity.contains(canary), "Activity contains closed metadata, not native or local transcript text")
        }
        await wrongProfile.stopBeforeTermination()
        await model.stopBeforeTermination()
        try await handoverScenario()
        print("[codex-native-workspace-check] PASS: synthetic connect, paged browse, explicit native review/link, streamed native IDs, approvals and input, exact permission renewal, stop-during-start, disconnect/reconnect, unknown-delivery blocking, consented handover inside the native message, profile isolation and metadata-only Activity; zero CLI/provider/production access")
    }

    /// D30: with consent, a linked native chat is caught up on what Local
    /// wrote. The block travels inside the native message, is recorded once
    /// acknowledged, and Aitvaras shows only what the user typed.
    private static func handoverScenario() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-native-handover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("primary")
        let worktree = primary.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let roots = [primary.resolvingSymlinksInPath().path]
        let cwd = worktree.resolvingSymlinksInPath().path
        let stores = Stores(db: try AitvarasDatabase(url: nil))
        let reporter = ActivityReporter(stores: stores)
        let project = try stores.createWorkspaceProject(title: "Synthetic handover project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic handover chat", kind: .primary)
        try stores.appendMessage(StoredMessage(conversationID: chat.localConversationID, role: "user", content: "LOCAL_BEFORE_NATIVE_CANARY"))
        try stores.appendMessage(StoredMessage(conversationID: chat.localConversationID, role: "assistant", content: "LOCAL_ANSWER_CANARY"))
        try stores.setValue("1", forKey: "workspace.chat.\(chat.id).shareHistory.codex")
        let nativeProject = NativeProjectSnapshot(identity: .init(provider: .codex, hostID: "local",
            profileNamespace: "synthetic-profile", externalID: SyntheticNativeWorkspaceTransport.projectID),
            // The fake reports this native name; a different one would
            // correctly require the link to be reviewed again.
            name: "Synthetic native project", roots: roots.map { .init(path: $0) })
        _ = try stores.linkWorkspaceCodexProject(projectID: project.id, snapshot: nativeProject,
            reviewedRoots: Stores.workspaceCodexRootReviews(for: nativeProject), reviewed: true)
        let fake = SyntheticNativeWorkspaceTransport(roots: roots, cwd: cwd)
        let model = CodexNativeWorkspaceModel()
        try model.configure(stores: stores, reporter: reporter, transport: fake, profileNamespace: "synthetic-profile")
        model.load(chatID: chat.id)
        await model.connect()
        await model.browseChats(projectID: project.id)
        await model.reviewChat(threadID: SyntheticNativeWorkspaceTransport.threadID)
        try require(await model.linkReviewedChat(chatID: chat.id), "Handover chat linked")
        let link = try needed(try stores.workspaceCodexChatLink(chatID: chat.id), "Handover link")

        let prompt = "SYNTHETIC_HANDOVER_PROMPT"
        let sending = Task { @MainActor in await model.sendFromComposer(prompt: prompt, chatID: chat.id, modelID: "synthetic-model", effort: nil) }
        try await waitUntil("Handover turn acknowledged") { await fake.startCount == 1 && model.nativeWorkActive }
        let wire = await fake.lastPrompt
        try require(wire.hasPrefix(WorkspaceHandoverText.header) && wire.contains("LOCAL_BEFORE_NATIVE_CANARY")
            && wire.contains("LOCAL_ANSWER_CANARY") && wire.hasSuffix("\n" + prompt), "Consented handover travels inside the native message")
        await fake.complete(turnID: await fake.latestTurnID)
        try await waitUntil("Handover turn completed") { !model.isBusy }
        _ = await sending.value
        try require(try stores.workspaceHandovers(chatID: chat.id).count == 1, "Handover recorded once acknowledged")
        let shown = try stores.workspaceChatTimeline(chatID: chat.id)
        try require(shown.contains { $0.role == "user" && $0.provider == "codex" && $0.text == prompt }, "Native message shown without its handover block")
        try require(shown.contains { $0.role == "handover" }, "Handover visible in the transcript")
        try require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.codexNative(link.id)) == nil,
            "Native thread is up to date after its handover")
        // Local sees the native turn as typed, never the nested block.
        let onward = try needed(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.local), "Codex turn travels onward")
        try require(onward.text.contains("[user · Codex] \(prompt)") && !onward.text.contains("LOCAL_BEFORE_NATIVE_CANARY"),
            "A handover is never handed on again")
        await model.stopBeforeTermination()
    }

    private static func require(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure.assertion(label) }
    }

    private static func needed<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw Failure.assertion(label) }
        return value
    }

    private static func waitUntil(_ label: String, _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        throw Failure.timedOut(label)
    }
}

private actor SyntheticNativeWorkspaceTransport: CodexNativeWorkspaceTransport {
    static let projectID = "synthetic-native-project"
    static let threadID = "synthetic-native-thread"
    enum Mode { case manual, holdStart, loseStartResponse }
    private struct Turn: Sendable {
        let id: String
        var status: String
        let prompt: String
        var output: String
        let clientUserMessageID: String?
    }
    let roots: [String]
    let cwd: String
    private var mode = Mode.manual
    private var networkAccess = false
    private var continuation: AsyncStream<CodexNativeEvent>.Continuation?
    private var heldStart: CheckedContinuation<Void, Never>?
    private var turns: [Turn] = [.init(id: "synthetic-historical-turn", status: "completed",
        prompt: "Synthetic historical question", output: "Synthetic historical answer", clientUserMessageID: nil)]
    private(set) var callCount = 0
    private(set) var startCount = 0
    private(set) var resumeCount = 0
    private(set) var snapshotCount = 0
    private(set) var interruptCount = 0
    private(set) var responseCount = 0
    private(set) var lastResponse: CodexJSONValue?
    private(set) var lastPrompt = ""
    private(set) var lastClientUserMessageID: String?
    var latestTurnID: String { turns.last!.id }
    var isStartHeld: Bool { heldStart != nil }

    init(roots: [String], cwd: String) { self.roots = roots; self.cwd = cwd }
    func setMode(_ value: Mode) { mode = value }
    func setNetworkAccess(_ value: Bool) { networkAccess = value }
    func releaseStart() { heldStart?.resume(); heldStart = nil }
    func counters() -> (starts: Int, resumes: Int, snapshots: Int, interrupts: Int) {
        (startCount, resumeCount, snapshotCount, interruptCount)
    }

    func connect() async throws -> CodexNativeConnectionInfo {
        callCount += 1
        return .init(transport: "Synthetic in-memory transport", detail: "Synthetic fixture; no runtime was started")
    }

    func events() async -> AsyncStream<CodexNativeEvent> {
        let pair = AsyncStream<CodexNativeEvent>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        continuation = pair.continuation
        return pair.stream
    }

    func request(method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        callCount += 1
        switch method {
        case "account/read": return ["account": ["type": "syntheticAccount"]]
        case "model/list": return ["data": [["id": "synthetic-model", "displayName": "Synthetic model", "supportedReasoningEfforts": [["reasoningEffort": "medium"]]]]]
        case "account/rateLimits/read": return ["rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 300]]]
        case "project/read":
            guard params["projectId"]?.stringValue == Self.projectID else { throw CodexNativeError.invalidRequest }
            return ["project": ["id": .string(Self.projectID), "name": "Synthetic native project", "roots": .array(roots.map { ["path": .string($0)] })]]
        case "thread/list":
            guard params["projectId"]?.stringValue == Self.projectID else { throw CodexNativeError.invalidRequest }
            if params["cursor"] == .string("synthetic-next-page") {
                return ["data": [["id": "synthetic-other-thread", "name": "Synthetic native chat", "cwd": .string(cwd), "status": ["type": "idle"]]], "nextCursor": .null]
            }
            return ["data": [["id": .string(Self.threadID), "name": "Synthetic native chat", "cwd": .string(cwd), "status": ["type": "idle"]]], "nextCursor": "synthetic-next-page"]
        case "turn/interrupt":
            guard params["threadId"]?.stringValue == Self.threadID, let id = params["turnId"]?.stringValue,
                  turns.contains(where: { $0.id == id }) else { throw CodexNativeError.invalidRequest }
            interruptCount += 1
            complete(turnID: id, status: "interrupted")
            return [:]
        default: throw CodexNativeError.invalidRequest
        }
    }

    func resume(threadID: String) async throws -> CodexNativeResumeConfiguration {
        callCount += 1; resumeCount += 1
        guard threadID == Self.threadID else { throw CodexNativeError.invalidRequest }
        return .init(threadID: threadID, model: "synthetic-model", modelProvider: "synthetic-provider", cwd: cwd,
            approvalPolicy: "on-request", approvalsReviewer: "user",
            sandbox: ["type": "workspaceWrite", "writableRoots": [.string(roots.last!)], "networkAccess": .bool(networkAccess)],
            runtimeWorkspaceRoots: roots, activePermissionProfile: nil, raw: [:])
    }

    func canonicalSnapshot(threadID: String) async throws -> CodexNativeThreadSnapshot {
        callCount += 1; snapshotCount += 1
        guard threadID == Self.threadID else { throw CodexNativeError.invalidRequest }
        let nativeTurns = turns.enumerated().map { index, turn in
            CodexNativeTurnSnapshot(id: turn.id, status: turn.status, order: index,
                raw: ["id": .string(turn.id), "status": .string(turn.status), "startedAt": .int(1_800_000_000 + index)])
        }
        var items: [CodexNativeItemSnapshot] = []
        for (index, turn) in turns.enumerated() {
            let userID = "synthetic-user-\(index)"
            var user: [String: CodexJSONValue] = ["id": .string(userID), "type": "userMessage", "content": [["type": "text", "text": .string(turn.prompt)]]]
            if let clientID = turn.clientUserMessageID { user["clientUserMessageId"] = .string(clientID) }
            items.append(.init(id: userID, turnID: turn.id, kind: "userMessage", order: index * 10,
                raw: ["item": .object(user), "startedAtMs": .int((1_800_000_000 + index) * 1000)]))
            if !turn.output.isEmpty {
                let id = "synthetic-agent-\(index)"
                items.append(.init(id: id, turnID: turn.id, kind: "agentMessage", order: index * 10 + 1,
                    raw: ["item": ["id": .string(id), "type": "agentMessage", "text": .string(turn.output)]]))
            }
            if index == 0 {
                items.append(.init(id: "synthetic-future-tool", turnID: turn.id, kind: "syntheticFutureTool", order: 2,
                    raw: ["item": ["id": "synthetic-future-tool", "type": "syntheticFutureTool", "unknownFields": ["retain": true]]]))
            }
        }
        return .init(id: Self.threadID, name: "Synthetic native chat", projectID: Self.projectID, cwd: cwd,
            status: turns.contains(where: { $0.status == "inProgress" }) ? "active" : "idle", raw: ["unknownThreadField": true],
            turns: nativeTurns, items: items, complete: true)
    }

    func startTurn(threadID: String, text: String, model: String?, effort: String?, clientUserMessageID: String?) async throws -> CodexJSONValue {
        guard threadID == Self.threadID, !turns.contains(where: { $0.status == "inProgress" }) else { throw CodexNativeError.busy }
        callCount += 1; startCount += 1; lastPrompt = text; lastClientUserMessageID = clientUserMessageID
        let id = "synthetic-native-turn-\(startCount)"
        turns.append(.init(id: id, status: "inProgress", prompt: text, output: "", clientUserMessageID: clientUserMessageID))
        continuation?.yield(.notification(method: "turn/started", params: ["threadId": .string(Self.threadID), "turn": ["id": .string(id), "status": "inProgress"]]))
        switch mode {
        case .manual: break
        case .holdStart: await withCheckedContinuation { heldStart = $0 }
        case .loseStartResponse:
            emitDisconnect()
            throw CodexNativeError.disconnected
        }
        return ["turn": ["id": .string(id), "status": "inProgress"]]
    }

    func respond(to requestID: CodexJSONValue, threadID: String, turnID: String, result: CodexJSONValue) async throws {
        guard threadID == Self.threadID, turns.contains(where: { $0.id == turnID && $0.status == "inProgress" }) else { throw CodexNativeError.approvalScope }
        callCount += 1; responseCount += 1; lastResponse = result
    }

    func emit(_ event: CodexNativeEvent) { continuation?.yield(event) }

    func emitText(_ text: String, turnID: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].output += text
        continuation?.yield(.notification(method: "item/agentMessage/delta", params: ["threadId": .string(Self.threadID),
            "turnId": .string(turnID), "itemId": .string("synthetic-agent-\(index)"), "delta": .string(text)]))
    }

    func complete(turnID: String, status: String = "completed") {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].status = status
        continuation?.yield(.notification(method: "turn/completed", params: ["threadId": .string(Self.threadID),
            "turn": ["id": .string(turnID), "status": .string(status)]]))
        continuation?.yield(.notification(method: "thread/status/changed", params: ["threadId": .string(Self.threadID), "status": ["type": "idle"]]))
    }

    func emitDisconnect() {
        continuation?.yield(.disconnected)
        continuation?.finish(); continuation = nil
    }

    func disconnect() async {
        continuation?.finish(); continuation = nil
        releaseStart()
    }
}
