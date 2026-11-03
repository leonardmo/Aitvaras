import Foundation
import Observation
import CryptoKit
import AitvarasCore
import AitvarasConnectors
import AitvarasStore

struct CodexNativeChatChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let directory: String
    let activity: String
}

struct CodexNativeChatReview: Equatable {
    let threadID: String
    let title: String
    let workingDirectory: String
    let approvalPolicy: String
    let sandbox: String
    let toolSummary: String
    let canContinue: Bool
    let warning: String?
    let writableRoots: [String]
    let networkAccess: String
}

struct CodexNativeApproval: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let kind: String
    let canAllow: Bool
    var questions: [CodexNativeQuestion] = []
}

struct CodexNativeQuestion: Identifiable, Equatable {
    let id: String
    let title: String
    let options: [String]
}

protocol CodexNativeWorkspaceTransport: Sendable {
    func connect() async throws -> CodexNativeConnectionInfo
    func events() async -> AsyncStream<CodexNativeEvent>
    func request(method: String, params: CodexJSONValue) async throws -> CodexJSONValue
    func canonicalSnapshot(threadID: String) async throws -> CodexNativeThreadSnapshot
    func resume(threadID: String) async throws -> CodexNativeResumeConfiguration
    func startTurn(threadID: String, text: String, model: String?, effort: String?, clientUserMessageID: String?) async throws -> CodexJSONValue
    func respond(to requestID: CodexJSONValue, threadID: String, turnID: String, result: CodexJSONValue) async throws
    func disconnect() async
}

extension CodexNativeClient: CodexNativeWorkspaceTransport {}

/// Native shared chats never pass through the isolated owned-thread registry.
/// All provider input is journalled once; disconnection never authorizes replay.
@MainActor @Observable
final class CodexNativeWorkspaceModel {
    private(set) var isBusy = false
    private(set) var isConnected = false
    private(set) var nativeWorkActive = false
    private(set) var authenticated = false
    private(set) var status: String?
    private(set) var errorMessage: String?
    private(set) var projectIssue: String?
    private(set) var models: [CodexInteractiveModel] = []
    private(set) var usageWindows: [CodexUsageWindow] = []
    private(set) var contextUsedTokens: Int?
    private(set) var contextLimitTokens: Int?
    private(set) var threadChoices: [CodexNativeChatChoice] = []
    private(set) var linkReview: CodexNativeChatReview?
    private(set) var pendingApprovals: [CodexNativeApproval] = []
    private(set) var liveEntries: [WorkspaceChatTimelineEntry] = []
    private(set) var transcriptRevision = 0
    private(set) var projectLink: WorkspaceCodexProjectLink?
    private(set) var chatLink: WorkspaceCodexChatLink?
    var endpoint = ""

    @ObservationIgnored private var stores: Stores?
    @ObservationIgnored private var reporter: ActivityReporter?
    @ObservationIgnored private var client: (any CodexNativeWorkspaceTransport)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var foregroundRefresh: Task<Void, Never>?
    @ObservationIgnored private var selectedChatID: UUID?
    @ObservationIgnored private var reviewConfiguration: CodexNativeResumeConfiguration?
    @ObservationIgnored private var reviewSnapshot: CodexNativeThreadSnapshot?
    @ObservationIgnored private var pendingRequests: [String: CodexNativeServerRequest] = [:]
    @ObservationIgnored private var operation: WorkspaceCodexNativeOperation?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var activeTurnID: String?
    @ObservationIgnored private var terminalTurns: [String: String] = [:]
    @ObservationIgnored private var observedTurnID: String?
    @ObservationIgnored private var itemDetails: [String: CodexJSONValue] = [:]
    @ObservationIgnored private var completion: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var configurationEndpoint: String?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var injectedTransport: (any CodexNativeWorkspaceTransport)?
    @ObservationIgnored private var profileNamespace = CodexSessionReader().profileNamespace

    func configure(stores: Stores, reporter: ActivityReporter?, transport: (any CodexNativeWorkspaceTransport)? = nil,
                   profileNamespace: String? = nil) throws {
        guard self.stores == nil else { return }
        _ = try stores.reconcileUnfinishedWorkspaceCodexNativeOperations()
        self.stores = stores; self.reporter = reporter; injectedTransport = transport
        if let profileNamespace { self.profileNamespace = profileNamespace }
        endpoint = try stores.value(forKey: "workspace.codex.native.endpoint") ?? ""
    }

    func isLinked(chatID: UUID) -> Bool {
        (try? stores?.workspaceCodexChatLink(chatID: chatID)) != nil
    }

    func prefersNative(chatID: UUID) -> Bool {
        if isLinked(chatID: chatID) { return true }
        if let choice = try? stores?.value(forKey: "workspace.chat.\(chatID).codex.connectionMode") {
            return choice == "native"
        }
        return (try? stores?.workspaceFrontierSessions(chatID: chatID).isEmpty) ?? true
    }

    func chooseConnectionMode(chatID: UUID, native: Bool) {
        guard !isBusy, !isLinked(chatID: chatID) else { return }
        do { try stores?.setValue(native ? "native" : "isolated", forKey: "workspace.chat.\(chatID).codex.connectionMode") }
        catch { errorMessage = "The connection choice could not be saved." }
        load(chatID: chatID)
    }

    func load(chatID: UUID) {
        guard !isBusy || selectedChatID == chatID else { return }
        let changed = selectedChatID != chatID
        selectedChatID = chatID
        if changed { liveEntries = []; contextUsedTokens = nil; contextLimitTokens = nil; linkReview = nil }
        do {
            guard let stores, let chat = try stores.workspaceChat(id: chatID) else { return }
            chatLink = try stores.workspaceCodexChatLink(chatID: chatID)
            projectLink = try stores.workspaceCodexProjectLink(projectID: chat.projectID)
            projectIssue = projectLink?.state != .linked ? "Link and review this project in Project settings."
                : chatLink == nil ? "Choose or create a linked Codex chat in AI Settings." : nil
            if let chatLink, let projection = try stores.workspaceCodexNativeProjection(chatLinkID: chatLink.id) {
                nativeWorkActive = projection.threadState == .active
                observedTurnID = projection.snapshot.turns.last(where: { $0.status == "inProgress" })?.id
            } else { nativeWorkActive = false; observedTurnID = nil }
            if let chatLink, let unresolved = try stores.workspaceCodexNativeOperations(chatLinkID: chatLink.id, unresolvedOnly: true).first {
                projectIssue = unresolved.state == .deliveryUnknown ? "Previous delivery is uncertain. Refresh native history; nothing will be resent." : nil
            }
            transcriptRevision += 1
        } catch { errorMessage = "Saved native chat details could not be loaded. Nothing was sent." }
        if changed && isConnected && chatLink != nil {
            foregroundRefresh?.cancel()
            foregroundRefresh = Task { @MainActor [weak self] in await self?.refreshHistory() }
        }
    }

    func connect() async {
        guard !isBusy, !terminating else { return }
        isBusy = true
        let id = begin("Connect shared Codex", stage: "Connecting to the existing native runtime", access: "Native account, model catalog and quota metadata")
        defer { isBusy = false }
        do {
            try await ensureConnection()
            try await loadCatalog()
            errorMessage = nil
            status = "Connected to shared Codex"
            finish(id, .succeeded, "Shared native runtime connected; no model prompt sent")
        } catch {
            isConnected = false
            errorMessage = safeError(error)
            finish(id, .failed, "Shared native runtime unavailable; no model prompt sent")
        }
    }

    private func ensureConnection() async throws {
        guard !terminating else { throw CancellationError() }
        let requested = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if isConnected && configurationEndpoint == requested { return }
        let generation = UUID(); connectionGeneration = generation
        eventTask?.cancel()
        if let client { await client.disconnect() }
        let configuration = CodexNativeConnectionConfiguration(
            transport: requested.isEmpty ? .defaultProxy : .loopbackWebSocket(requested),
            profileNamespace: profileNamespace)
        let transport: any CodexNativeWorkspaceTransport = injectedTransport ?? CodexNativeClient(configuration: configuration)
        let events = await transport.events()
        _ = try await transport.connect()
        client = transport; configurationEndpoint = requested; isConnected = true
        try stores?.setValue(requested, forKey: "workspace.codex.native.endpoint")
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, self?.connectionGeneration == generation else { return }
                await self?.receive(event)
            }
        }
    }

    private func loadCatalog() async throws {
        guard let client else { throw CodexNativeError.unavailable }
        let account = try await client.request(method: "account/read", params: ["refreshToken": false])
        authenticated = account["account"] != nil && account["account"] != .null
        let result = try await client.request(method: "model/list", params: ["limit": 100])
        models = (result["data"]?.arrayValue ?? []).compactMap { value in
            guard let id = value["id"]?.stringValue else { return nil }
            return CodexInteractiveModel(id: id, displayName: value["displayName"]?.stringValue ?? id,
                efforts: (value["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap { $0["reasoningEffort"]?.stringValue })
        }
        if let limits = try? await client.request(method: "account/rateLimits/read", params: [:]) { updateUsage(limits) }
    }

    func browseChats(projectID: UUID) async {
        guard !isBusy, let stores else { return }
        isBusy = true
        let id = begin("Browse linked Codex chats", stage: "Reading native project chats", access: "Reviewed native project and chat metadata")
        defer { isBusy = false }
        do {
            guard let saved = try stores.workspaceCodexProjectLink(projectID: projectID), saved.state == .linked,
                  saved.approvedSnapshot.identity.hostID == "local",
                  saved.approvedSnapshot.identity.profileNamespace == profileNamespace else {
                throw WorkspaceCodexLinkError.reviewRequired
            }
            projectLink = saved
            try await ensureConnection()
            guard let client else { throw CodexNativeError.unavailable }
            try await verifyProject(saved)
            var choices: [CodexNativeChatChoice] = [], cursor: CodexJSONValue = .null, seen = Set<String>()
            for _ in 0..<100 {
                let page = try await client.request(method: "thread/list", params: ["projectId": .string(saved.approvedSnapshot.identity.externalID), "limit": 50, "cursor": cursor])
                for item in page["data"]?.arrayValue ?? [] {
                    guard let nativeID = item["id"]?.stringValue, seen.insert(nativeID).inserted else { continue }
                    choices.append(.init(id: nativeID, title: item["name"]?.stringValue ?? item["preview"]?.stringValue ?? "Codex chat",
                        directory: item["cwd"]?.stringValue ?? "", activity: Self.threadStatus(item)))
                }
                let next = page["nextCursor"] ?? .null
                if next == .null { cursor = .null; break }
                guard next != cursor else { throw CodexNativeError.malformed }
                cursor = next
            }
            guard cursor == .null else { throw CodexNativeError.tooLarge }
            threadChoices = choices; errorMessage = nil
            finish(id, .succeeded, "Native chat metadata loaded; no turn started")
        } catch { errorMessage = safeError(error); finish(id, .failed, "Native chat list unavailable; previous links retained") }
    }

    func reviewChat(threadID: String) async {
        guard !isBusy else { return }
        isBusy = true
        let id = begin("Review native Codex chat", stage: "Reading history and effective permissions", access: "Selected native chat and effective native permissions")
        defer { isBusy = false }
        do {
            try await ensureConnection()
            guard let client, let projectLink else { throw WorkspaceCodexLinkError.reviewRequired }
            try await verifyProject(projectLink)
            let config = try await client.resume(threadID: threadID)
            let snapshot = try await client.canonicalSnapshot(threadID: threadID)
            try verifyMembership(snapshot, project: projectLink)
            setReview(config, snapshot: snapshot)
            errorMessage = nil
            finish(id, .succeeded, "Native chat and permissions ready for explicit linking; no turn started")
        } catch { linkReview = nil; errorMessage = safeError(error); finish(id, .failed, "Native chat review not completed") }
    }

    func prepareNewChat(chatID: UUID, workingDirectory: String) async {
        guard !isBusy, let stores, let local = try? stores.workspaceChat(id: chatID),
              let project = try? stores.workspaceCodexProjectLink(projectID: local.projectID), project.state == .linked else { return }
        isBusy = true
        let id = begin("Prepare native Codex chat", stage: "Creating an empty native chat", access: "Reviewed project and explicit working directory")
        defer { isBusy = false }
        do {
            try await ensureConnection()
            guard let client else { throw CodexNativeError.unavailable }
            try await verifyProject(project)
            let cwdURL = URL(fileURLWithPath: workingDirectory).standardizedFileURL.resolvingSymlinksInPath()
            guard project.approvedRoots.contains(where: { root in
                guard let path = root.canonicalPath, root.availability == .available else { return false }
                return cwdURL.path == path || cwdURL.path.hasPrefix(path + "/")
            }) else { throw WorkspaceCodexLinkError.invalidWorkingDirectory }
            let result = try await client.request(method: "thread/start", params: ["projectId": .string(project.approvedSnapshot.identity.externalID), "cwd": .string(cwdURL.path)])
            guard let nativeID = result["thread"]?["id"]?.stringValue else { throw CodexNativeError.malformed }
            let config = try CodexNativeClient.effectiveConfiguration(result, expectedThreadID: nativeID)
            let raw = result["thread"] ?? [:]
            let snapshot = CodexNativeThreadSnapshot(id: nativeID, name: local.title,
                projectID: project.approvedSnapshot.identity.externalID, cwd: config.cwd, status: "idle", raw: raw,
                turns: [], items: [], complete: true)
            projectLink = project; setReview(config, snapshot: snapshot)
            errorMessage = nil
            status = "Empty native chat prepared. Link it, then send your first message."
            finish(id, .succeeded, "Empty native thread created; no model prompt sent")
        } catch { errorMessage = safeError(error); finish(id, .failed, "Empty native thread not verified; no prompt sent or replayed") }
    }

    @discardableResult func linkReviewedChat(chatID: UUID) async -> Bool {
        guard !isBusy, let stores, let projectLink, let config = reviewConfiguration,
              let snapshot = reviewSnapshot, linkReview?.canContinue == true else { return false }
        isBusy = true
        let id = begin("Link native Codex chat", stage: "Saving reviewed native relationship", access: "Explicitly reviewed native history and permissions")
        defer { isBusy = false }
        do {
            try await verifyProject(projectLink)
            let link: WorkspaceCodexChatLink
            if let existing = try stores.workspaceCodexChatLink(chatID: chatID) {
                guard existing.externalID == snapshot.id, existing.projectLinkID == projectLink.id,
                      existing.workingDirectory == config.cwd else { throw WorkspaceCodexLinkError.identityMismatch }
                link = existing
            } else {
                link = try stores.linkWorkspaceCodexChat(chatID: chatID, projectLinkID: projectLink.id,
                    nativeProjectIdentity: projectLink.approvedSnapshot.identity, nativeThreadID: snapshot.id,
                    workingDirectory: config.cwd, expectedProjectRevision: projectLink.revision, reviewed: true)
            }
            let previous = try stores.workspaceCodexNativeProjection(chatLinkID: link.id)
            _ = try stores.replaceWorkspaceCodexNativeProjection(chatLinkID: link.id, snapshot: snapshot,
                expectedProjectRevision: projectLink.revision, expectedChatRevision: link.revision, expectedProjectionRevision: previous?.revision)
            _ = try stores.authorizeWorkspaceCodexNativeTools(chatLinkID: link.id, expectedProjectRevision: projectLink.revision,
                expectedChatRevision: link.revision, effectiveConfigurationFingerprint: fingerprint(config),
                reviewedPolicySummary: "\(linkReview!.sandbox); \(linkReview!.approvalPolicy); normal native Codex tools", reviewed: true)
            chatLink = link; selectedChatID = chatID; projectIssue = nil; errorMessage = nil
            try stores.setValue("native", forKey: "workspace.chat.\(chatID).codex.connectionMode")
            liveEntries = []; transcriptRevision += 1
            if models.isEmpty { try? await loadCatalog() }
            finish(id, .succeeded, "Native chat linked; exact native permissions reviewed; no model turn started")
            return true
        } catch { load(chatID: chatID); errorMessage = safeError(error); finish(id, .failed, "Native link not completed; no model turn started"); return false }
    }

    func unlinkChat(chatID: UUID) {
        guard !isBusy, let stores else { return }
        do {
            if let link = try stores.workspaceCodexChatLink(chatID: chatID) {
                try stores.unlinkWorkspaceCodexChat(linkID: link.id, expectedRevision: link.revision)
            }
            chatLink = nil; liveEntries = []; projectIssue = nil; transcriptRevision += 1
            status = "Unlinked locally. The native Codex chat was kept."
        } catch { errorMessage = "The native link could not be removed. Saved history was kept." }
    }

    func refreshHistory() async {
        guard !isBusy, let chatLink else { return }
        isBusy = true
        let id = begin("Refresh native Codex chat", stage: "Reading canonical native history", access: "Explicitly linked native chat history and state")
        defer { isBusy = false }
        do {
            try await ensureConnection()
            guard let client else { throw CodexNativeError.unavailable }
            guard let project = try stores?.workspaceCodexProjectLink(projectID: chatLink.projectID) else { throw WorkspaceCodexLinkError.reviewRequired }
            try await verifyProject(project)
            let configuration = try await client.resume(threadID: chatLink.externalID)
            try await refreshProjection(chatLink)
            if let saved = try stores?.workspaceCodexNativeProjection(chatLinkID: chatLink.id) {
                setReview(configuration, snapshot: saved.snapshot)
            }
            errorMessage = nil; finish(id, .succeeded, "Canonical native history refreshed; no input sent")
        } catch { errorMessage = safeError(error); finish(id, .failed, "Native history unavailable; saved observation retained") }
    }

    static let maximumNativeMessageBytes = 200_000

    @discardableResult func sendFromComposer(prompt: String, chatID: UUID, modelID: String, effort: String?) async -> Bool {
        guard !isBusy, !terminating, selectedChatID == chatID, let stores,
              let link = try? stores.workspaceCodexChatLink(chatID: chatID),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= Self.maximumNativeMessageBytes else { return false }
        isBusy = true; errorMessage = nil
        runID = begin("Codex native response", stage: "Checking native chat and reviewed permissions", access: "Linked native history, project files and tools under native Codex permissions")
        var recorded = false
        let task = Task { @MainActor in
            defer { self.isBusy = false; self.pendingApprovals = []; self.pendingRequests = [:]; self.activeTurnID = nil; self.worker = nil; self.operation = nil; self.runID = nil }
            do {
                try await self.ensureConnection()
                guard let client = self.client, let project = try stores.workspaceCodexProjectLink(projectID: link.projectID) else { throw WorkspaceCodexLinkError.reviewRequired }
                try await self.verifyProject(project)
                let cached = try stores.workspaceCodexNativeProjection(chatLinkID: link.id)
                let config: CodexNativeResumeConfiguration
                if cached?.snapshot.turns.isEmpty == true, let prepared = self.reviewConfiguration,
                   prepared.threadID == link.externalID {
                    config = prepared
                } else { config = try await client.resume(threadID: link.externalID) }
                guard self.configurationAllowed(config) else { throw CodexNativeError.unreviewedConfiguration }
                let snapshot = try await client.canonicalSnapshot(threadID: link.externalID)
                let previous = try stores.workspaceCodexNativeProjection(chatLinkID: link.id)
                let projection = try stores.replaceWorkspaceCodexNativeProjection(chatLinkID: link.id, snapshot: snapshot,
                    expectedProjectRevision: project.revision, expectedChatRevision: link.revision, expectedProjectionRevision: previous?.revision)
                self.transcriptRevision += 1
                // D30: with this chat's consent, catch the shared thread up on
                // what other threads wrote. The block travels inside the
                // message, so it is visible in Codex desktop as well.
                let shareAllowed = try stores.value(forKey: "workspace.chat.\(chatID).shareHistory.codex") == "1"
                let handover = shareAllowed ? try stores.workspaceHandoverPlan(chatID: chatID,
                    threadKey: WorkspaceThreadKey.codexNative(link.id), fittingBeside: prompt,
                    maximumBytes: Self.maximumNativeMessageBytes) : nil
                var op = try stores.requestWorkspaceCodexNativeOperation(chatLinkID: link.id, kind: .send, userMessage: prompt,
                    expectedProjectRevision: project.revision, expectedChatRevision: link.revision,
                    expectedProjectionRevision: projection.revision, effectiveConfigurationFingerprint: self.fingerprint(config))
                recorded = true; self.operation = op
                op = try stores.prepareWorkspaceCodexNativeOperation(id: op.id, expectedRevision: op.revision)
                try Task.checkCancellation()
                op = try stores.beginWorkspaceCodexNativeDelivery(id: op.id, expectedRevision: op.revision)
                self.operation = op
                self.reporter?.update(id: self.runID!, stage: "Sending once to the shared native thread")
                let result = try await client.startTurn(threadID: link.externalID,
                    text: WorkspaceHandoverText.wire(handover: handover?.text, message: prompt), model: modelID.isEmpty ? nil : modelID,
                    effort: effort, clientUserMessageID: op.id.uuidString)
                guard let turnID = result["turn"]?["id"]?.stringValue else { throw CodexNativeError.uncertainOutcome }
                self.activeTurnID = turnID
                let current = try stores.workspaceCodexNativeOperation(id: op.id) ?? op
                self.operation = try stores.acknowledgeWorkspaceCodexNativeOperation(id: op.id, nativeTurnID: turnID, expectedRevision: current.revision)
                if let handover {
                    // Acknowledged, so the watermark may move. Failing to record
                    // only repeats these messages next time; it never ends the turn.
                    _ = try? stores.recordWorkspaceHandover(handover, chatID: chatID, turnID: op.id,
                                                            anchor: op.createdAt.addingTimeInterval(-0.001))
                }
                if current.cancellationRequestedAt != nil {
                    _ = try await client.request(method: "turn/interrupt", params: ["threadId": .string(link.externalID), "turnId": .string(turnID)])
                }
                self.reporter?.update(id: self.runID!, stage: "Codex is working with native tools")
                if self.isConnected && self.terminalTurns[turnID] == nil {
                    await withCheckedContinuation { self.completion = $0 }
                }
                if self.isConnected { try await self.refreshProjection(link) }
                if let saved = try stores.workspaceCodexNativeOperation(id: op.id), saved.state.isTerminal {
                    self.finish(self.runID, saved.state == .completed ? .succeeded : saved.state == .interrupted || saved.state == .cancelled ? .cancelled : .failed,
                        "Native Codex turn reached a confirmed terminal outcome")
                } else {
                    self.errorMessage = "Codex's outcome is not confirmed. Refresh history; the message will not be sent again."
                    self.finish(self.runID, .interrupted, "Native outcome unknown; input retained and never replayed")
                }
            } catch {
                self.errorMessage = self.safeError(error)
                if let op = self.operation, let current = try? stores.workspaceCodexNativeOperation(id: op.id), !current.state.isTerminal {
                    let undelivered = [.requested, .prepared].contains(current.state)
                    _ = try? stores.finishWorkspaceCodexNativeOperation(id: current.id,
                        state: undelivered ? .failed : .deliveryUnknown,
                        expectedRevision: current.revision, failureCode: undelivered ? "not_delivered" : "native_operation_unconfirmed")
                }
                self.finish(self.runID, recorded ? .interrupted : .failed,
                    recorded ? "Native outcome not confirmed; no input replay" : "Native send stopped before provider execution")
            }
        }
        worker = task
        await task.value
        return recorded
    }

    func stop() async {
        guard let client else { return }
        if operation == nil {
            if nativeWorkActive, let observedTurnID, let chatLink {
                let id = begin("Stop native Codex work", stage: "Requesting native interruption", access: "Observed native thread and turn identity")
                do {
                    _ = try await client.request(method: "turn/interrupt", params: ["threadId": .string(chatLink.externalID), "turnId": .string(observedTurnID)])
                    finish(id, .succeeded, "Interruption requested; native terminal outcome remains pending")
                } catch { finish(id, .outcomeUnknown, "Interruption was not confirmed; native work may continue") }
            } else { worker?.cancel(); foregroundRefresh?.cancel() }
            return
        }
        guard isBusy, let operation, let stores else { return }
        do {
            let current = try stores.workspaceCodexNativeOperation(id: operation.id) ?? operation
            self.operation = try stores.requestWorkspaceCodexNativeCancellation(id: current.id, expectedRevision: current.revision)
            if let runID { reporter?.update(id: runID, stage: "Stop requested; awaiting native confirmation", state: .cancellationRequested) }
            if let activeTurnID {
                _ = try await client.request(method: "turn/interrupt", params: ["threadId": .string(operation.nativeThreadID), "turnId": .string(activeTurnID)])
            }
        } catch { errorMessage = "Stop could not be confirmed. Native work may still be running." }
    }

    func respond(approvalID: String, allow: Bool, answers: [String: String] = [:]) async {
        guard let request = pendingRequests[approvalID], let client,
              request.threadID == chatLink?.externalID,
              request.turnID == activeTurnID || activeTurnID == nil else { return }
        guard !allow || pendingApprovals.first(where: { $0.id == approvalID })?.canAllow == true else { return }
        let canAllow = request.method == "item/commandExecution/requestApproval" || request.method == "item/fileChange/requestApproval"
        do {
            let result: CodexJSONValue
            if canAllow { result = ["decision": .string(allow ? "accept" : "decline")] }
            else if request.method == "item/permissions/requestApproval" {
                result = ["permissions": allow ? request.params["permissions"] ?? [:] : [:], "scope": "turn"]
            }
            else if request.method == "mcpServer/elicitation/request" { result = ["action": "decline", "content": .null] }
            else {
                let questions = pendingApprovals.first(where: { $0.id == approvalID })?.questions ?? []
                let supplied = allow ? answers : [:]
                guard !allow || questions.allSatisfy({ supplied[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else { return }
                result = ["answers": .object(Dictionary(uniqueKeysWithValues: questions.compactMap { question in
                    supplied[question.id].map { (question.id, CodexJSONValue.object(["answers": .array([.string($0)])])) }
                }))]
            }
            try await client.respond(to: request.id, threadID: request.threadID, turnID: request.turnID, result: result)
            pendingRequests.removeValue(forKey: approvalID); pendingApprovals.removeAll { $0.id == approvalID }
            if let runID { reporter?.update(id: runID, stage: "Native approval answered", state: .running) }
        } catch { errorMessage = "This approval is no longer available. Refresh native status." }
    }

    private func receive(_ event: CodexNativeEvent) async {
        switch event {
        case .disconnected:
            isConnected = false; authenticated = false
            completion?.resume(); completion = nil
            pendingRequests = [:]; pendingApprovals = []
            errorMessage = "Shared Codex disconnected. Work may continue in Codex; no message will be replayed."
        case .serverRequest(let request):
            guard request.threadID == chatLink?.externalID else { return }
            let id = Self.requestKey(request.id)
            pendingRequests[id] = request
            let preview = approvalPreview(request)
            let command = preview.detail
            let questions: [CodexNativeQuestion] = request.method == "item/tool/requestUserInput" ? (request.params["questions"]?.arrayValue ?? []).compactMap { value in
                guard let id = value["id"]?.stringValue, let title = value["question"]?.stringValue else { return nil }
                return .init(id: id, title: title, options: (value["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue })
            } : []
            let validQuestions = !questions.isEmpty && Set(questions.map(\.id)).count == questions.count && questions.count <= 8
            let allowed = preview.canAllow || validQuestions
            pendingApprovals.removeAll { $0.id == id }
            pendingApprovals.append(.init(id: id, title: request.method.contains("fileChange") ? "File changes" : allowed ? "Command permission" : "Native input required",
                detail: validQuestions ? "" : command, kind: request.method, canAllow: allowed, questions: questions))
            if let runID { reporter?.update(id: runID, stage: "Waiting for your approval", state: .waiting) }
        case .notification(let method, let params):
            if method == "account/rateLimits/updated" { updateUsage(params); return }
            let threadID = params["threadId"]?.stringValue ?? params["thread"]?["id"]?.stringValue
            guard threadID == chatLink?.externalID else { return }
            if method == "turn/started", let turn = params["turn"], let id = turn["id"]?.stringValue {
                observedTurnID = id; nativeWorkActive = true
                status = "Codex is working"
            } else if method == "thread/status/changed" {
                let state = params["status"]?["type"]?.stringValue ?? "unknown"
                nativeWorkActive = state == "active"
                status = state == "idle" ? "Codex ready" : state == "active" ? "Codex is working" : "Native status unavailable"
            } else if method == "item/started" || method == "item/completed", let item = params["item"], let itemID = item["id"]?.stringValue {
                itemDetails[itemID] = item
            } else if method == "turn/completed", let turn = params["turn"], let id = turn["id"]?.stringValue {
                if id == observedTurnID { nativeWorkActive = false; observedTurnID = nil }
                terminalTurns[id] = turn["status"]?.stringValue ?? "unknown"
                if id == activeTurnID { completion?.resume(); completion = nil }
                else if !isBusy { await refreshHistory() }
            } else if method == "item/agentMessage/delta", let itemID = params["itemId"]?.stringValue,
                      let delta = params["delta"]?.stringValue, let turnID = params["turnId"]?.stringValue, let link = chatLink {
                let id = "native:\(link.id):\(turnID.utf8.count):\(turnID):\(itemID)"
                let old = liveEntries.first { $0.id == id }
                let prefix = old?.text ?? (try? stores?.workspaceCodexNativeItems(chatID: link.chatID).first(where: { $0.nativeItemID == itemID && $0.nativeTurnID == turnID })?.text) ?? ""
                liveEntries.removeAll { $0.id == id }
                liveEntries.append(.init(id: id, role: "assistant", text: prefix + delta,
                    timestamp: old?.timestamp ?? .now, provider: "codex", state: .running))
            } else if method == "thread/tokenUsage/updated" {
                let usage = params["tokenUsage"] ?? params
                contextUsedTokens = usage["last"]?["totalTokens"]?.intValue
                contextLimitTokens = usage["modelContextWindow"]?.intValue
            } else if method == "serverRequest/resolved", let requestID = params["requestId"] {
                let key = Self.requestKey(requestID)
                pendingRequests.removeValue(forKey: key); pendingApprovals.removeAll { $0.id == key }
            }
        }
    }

    private func refreshProjection(_ link: WorkspaceCodexChatLink) async throws {
        guard let stores, let client, let project = try stores.workspaceCodexProjectLink(projectID: link.projectID) else { throw WorkspaceCodexLinkError.reviewRequired }
        try await verifyProject(project)
        let snapshot = try await client.canonicalSnapshot(threadID: link.externalID)
        let old = try stores.workspaceCodexNativeProjection(chatLinkID: link.id)
        _ = try stores.replaceWorkspaceCodexNativeProjection(chatLinkID: link.id, snapshot: snapshot,
            expectedProjectRevision: project.revision, expectedChatRevision: link.revision, expectedProjectionRevision: old?.revision)
        liveEntries = []; transcriptRevision += 1
        nativeWorkActive = snapshot.status == "active"
        observedTurnID = snapshot.turns.last(where: { $0.status == "inProgress" })?.id
        projectIssue = try stores.workspaceCodexNativeOperations(chatLinkID: link.id, unresolvedOnly: true).isEmpty
            ? nil : "An earlier operation remains uncertain. It will not be replayed."
    }

    private func verifyProject(_ reviewed: WorkspaceCodexProjectLink) async throws {
        guard let stores, let client, reviewed.state == .linked,
              reviewed.approvedSnapshot.identity.hostID == "local",
              reviewed.approvedSnapshot.identity.profileNamespace == profileNamespace else {
            throw WorkspaceCodexLinkError.reviewRequired
        }
        let response = try await client.request(method: "project/read", params: ["projectId": .string(reviewed.approvedSnapshot.identity.externalID)])
        guard let raw = response["project"], raw["id"]?.stringValue == reviewed.approvedSnapshot.identity.externalID,
              let roots = raw["roots"]?.arrayValue else { throw CodexNativeError.malformed }
        var current = reviewed.observedSnapshot
        current.name = raw["name"]?.stringValue ?? current.name
        current.roots = try roots.map { item in guard let path = item["path"]?.stringValue else { throw CodexNativeError.malformed }; return NativeProjectRoot(path: path) }
        let actual = await Task.detached(priority: .utility) { Stores.workspaceCodexRootReviews(for: current) }.value
        if current.name != reviewed.approvedSnapshot.name || current.roots != reviewed.approvedSnapshot.roots || actual != reviewed.approvedRoots {
            projectLink = try stores.observeWorkspaceCodexProject(linkID: reviewed.id, snapshot: current,
                observedRoots: actual, expectedRevision: reviewed.revision)
            throw WorkspaceCodexLinkError.reviewRequired
        }
    }

    private func verifyMembership(_ snapshot: CodexNativeThreadSnapshot, project: WorkspaceCodexProjectLink) throws {
        guard snapshot.projectID == project.approvedSnapshot.identity.externalID else { throw WorkspaceCodexNativeError.identityMismatch }
    }

    private func setReview(_ config: CodexNativeResumeConfiguration, snapshot: CodexNativeThreadSnapshot) {
        reviewConfiguration = config; reviewSnapshot = snapshot
        let sandbox = config.sandbox["type"]?.stringValue ?? config.sandbox.stringValue ?? "Unknown sandbox"
        let allowed = configurationAllowed(config)
        let writable = config.sandbox["writableRoots"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let roots = Array(Set(writable + config.runtimeWorkspaceRoots)).sorted()
        let network = config.sandbox["networkAccess"]?.boolValue.map { $0 ? "Allowed by native sandbox" : "Blocked unless approved" } ?? "Native Codex policy"
        linkReview = .init(threadID: snapshot.id, title: snapshot.name ?? "Codex chat", workingDirectory: config.cwd,
            approvalPolicy: config.approvalPolicy.stringValue ?? "Custom approval rules", sandbox: sandbox,
            toolSummary: "Normal Codex tools, including configured native integrations",
            canContinue: allowed, warning: allowed ? nil : "Full Access, external sandboxes and automatic approval reviewers are not enabled by this link.",
            writableRoots: roots, networkAccess: network)
    }

    private func approvalPreview(_ request: CodexNativeServerRequest) -> (detail: String, canAllow: Bool) {
        var parts: [String] = []
        if let reason = request.params["reason"]?.stringValue { parts.append(reason) }
        if let cwd = request.params["cwd"]?.stringValue { parts.append("Working folder: \(cwd)") }
        if let root = request.params["grantRoot"]?.stringValue { parts.append("Requested folder: \(root)") }
        for key in ["networkApprovalContext", "additionalPermissions"] {
            if let value = request.params[key], value != .null, let data = try? value.encoded() {
                parts.append(String(decoding: data, as: UTF8.self))
            }
        }
        if request.method == "item/commandExecution/requestApproval", let command = request.params["command"]?.stringValue {
            parts.insert(command, at: 0)
            return (parts.joined(separator: "\n\n"), true)
        }
        if request.method == "item/commandExecution/requestApproval",
           let network = request.params["networkApprovalContext"], network["host"]?.stringValue != nil,
           network["protocol"]?.stringValue != nil {
            return (parts.joined(separator: "\n\n"), true)
        }
        if request.method == "item/permissions/requestApproval", let permissions = request.params["permissions"],
           permissions.objectValue != nil, let data = try? permissions.encoded() {
            parts.append("Requested for this turn only:\n" + String(decoding: data, as: UTF8.self))
            return (parts.joined(separator: "\n\n"), true)
        }
        if request.method == "item/fileChange/requestApproval", let itemID = request.itemID,
           let changes = itemDetails[itemID]?["changes"], let data = try? changes.encoded() {
            parts.insert(String(decoding: data, as: UTF8.self), at: 0)
            return (parts.joined(separator: "\n\n"), true)
        }
        parts.append("The full request cannot be approved here. Review it in Codex.")
        return (parts.joined(separator: "\n\n"), false)
    }

    private func configurationAllowed(_ config: CodexNativeResumeConfiguration) -> Bool {
        let sandbox = config.sandbox["type"]?.stringValue ?? config.sandbox.stringValue ?? ""
        return ["readOnly", "workspaceWrite", "read-only", "workspace-write"].contains(sandbox)
            && config.approvalsReviewer == "user"
    }

    private func fingerprint(_ config: CodexNativeResumeConfiguration) -> String {
        let value: CodexJSONValue = ["cwd": .string(config.cwd), "sandbox": config.sandbox,
            "approval": config.approvalPolicy, "reviewer": .string(config.approvalsReviewer),
            "roots": .array(config.runtimeWorkspaceRoots.map(CodexJSONValue.string)), "profile": config.activePermissionProfile ?? .null]
        return SHA256.hash(data: (try? value.encoded()) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    private func updateUsage(_ raw: CodexJSONValue) {
        let limits = raw["rateLimits"] ?? raw
        usageWindows = [limits["primary"], limits["secondary"]].compactMap { item in
            guard let item, let value = item["usedPercent"] else { return nil }
            let used: Double
            switch value { case .int(let number): used = Double(number); case .double(let number): used = number; default: return nil }
            return CodexUsageWindow(usedPercent: used, durationMinutes: item["windowDurationMins"]?.intValue,
                resetsAt: item["resetsAt"]?.intValue.map { Date(timeIntervalSince1970: Double($0)) })
        }
    }

    private static func threadStatus(_ raw: CodexJSONValue) -> String { raw["status"]?["type"]?.stringValue ?? "unknown" }
    private static func requestKey(_ id: CodexJSONValue) -> String { ((try? id.encoded()).map { String(decoding: $0, as: UTF8.self) }) ?? "invalid" }
    private func begin(_ title: String, stage: String, access: String) -> UUID? {
        reporter?.begin(ActivityRun(category: .cloud, trigger: .manual, title: title, stage: stage, provider: "Codex",
            executionLocation: "This Mac → shared Codex runtime", dataAccess: access,
            dataDestination: "Native Codex profile; OpenAI only on explicit Send"))
    }
    private func finish(_ id: UUID?, _ state: ActivityRunState, _ outcome: String) { if let id { reporter?.finish(id: id, state: state, outcome: outcome) } }
    private func safeError(_ error: Error) -> String {
        if let error = error as? CodexNativeError { return error.localizedDescription }
        if let error = error as? WorkspaceCodexNativeError { return error.localizedDescription }
        if let error = error as? WorkspaceCodexLinkError { return error.localizedDescription }
        return "Native Codex operation could not be confirmed. Saved history is retained; nothing is replayed."
    }

    func stopBeforeTermination() async {
        terminating = true
        foregroundRefresh?.cancel()
        // Quitting this observer must not interrupt work in the shared Codex
        // runtime (including work started in desktop). Only the explicit Stop
        // control sends turn/interrupt. Disconnect preserves uncertain delivery.
        worker?.cancel()
        await client?.disconnect()
        completion?.resume(); completion = nil
        await worker?.value
        eventTask?.cancel(); eventTask = nil; isConnected = false
    }
    func resumeAfterCancelledTermination() { terminating = false }
}
