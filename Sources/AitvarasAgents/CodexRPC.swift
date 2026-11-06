import Foundation

actor CodexRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let backend: CodexBackend
    private let wire: AgentWire
    private let session: AgentSessionID
    private let configuration: AgentSessionConfiguration
    private var mode: AgentMode
    private var input: UUID?
    private var turn: String?
    private var userInputs: [AgentInput] = []
    private var steering = false
    private var acknowledged = false
    private var closed = false
    private var requests: [AgentRequestID: AgentRequest] = [:]
    private var seenRequests: Set<AgentRequestID> = []
    private var completedTurns: Set<String> = []
    private var completedItems: Set<String> = []
    private var items: [String: JSONValue] = [:]
    private var proposedPlan: (id: String, text: String)?
    private var planRequestID: AgentRequestID?
    private var executingApprovedPlan = false

    init(backend: CodexBackend, wire: AgentWire, session: AgentSessionID, configuration: AgentSessionConfiguration) {
        self.backend = backend; self.wire = wire; self.session = session; self.configuration = configuration; mode = configuration.mode
        (events, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(4096))
    }
    func started() { emit(.sessionStarted(session)) }
    private func scope(item: String? = nil) -> AgentEventScope {
        AgentEventScope(runID: id, session: session, inputID: input, turnID: turn, itemID: item)
    }
    private func emit(_ kind: AgentEvent.Kind, item: String? = nil) {
        switch continuation.yield(AgentEvent(scope: scope(item: item), kind: kind)) {
        case .enqueued: break
        case .dropped, .terminated:
            continuation.finish(throwing: AgentFailure.invalidTransition)
            Task { try? await self.shutdown() }
        @unknown default: break
        }
    }
    private func acknowledge() {
        if input != nil, !acknowledged { acknowledged = true; emit(.delivery(.acknowledged)) }
    }
    func send(_ value: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed, input == nil else { throw AgentFailure.invalidTransition }
        let content = try contentForDelivery(value)
        input = value.id; userInputs = [value]; turn = nil; acknowledged = false; completedItems.removeAll(); items.removeAll()
        proposedPlan = nil; planRequestID = nil; executingApprovedPlan = false
        do { try await willDeliver() } catch { input = nil; throw error }
        guard !closed, input == value.id else { throw AgentFailure.invalidTransition }
        emit(.delivery(.deliveryUnknown))
        do {
            try await startTurn(content: content, mode: mode)
        } catch {
            if input == value.id { emit(.turnEnded(.failed((error as? AgentFailure) ?? .unknown))); input = nil; requests.removeAll() }
            throw error
        }
    }
    func followup(_ value: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed, input != nil, let turn, !completedTurns.contains(turn),
              planRequestID == nil, !steering else { throw AgentFailure.invalidTransition }
        let content = try contentForDelivery(value)
        steering = true
        defer { steering = false }
        try await willDeliver()
        guard !closed, input != nil, self.turn == turn, !completedTurns.contains(turn) else { throw AgentFailure.invalidTransition }
        let scope = AgentEventScope(runID: id, session: session, inputID: value.id, turnID: turn)
        continuation.yield(.init(scope: scope, kind: .delivery(.deliveryUnknown)))
        userInputs.append(value)
        let result = try await wire.request("turn/steer", .object([
            "threadId": .string(session.nativeID), "expectedTurnId": .string(turn),
            "clientUserMessageId": .string(value.id.uuidString),
            "input": content]))
        guard !closed, result["turnId"]?.stringValue == turn else { throw AgentFailure.invalidTransition }
        continuation.yield(.init(scope: scope, kind: .delivery(.acknowledged)))
    }
    private func contentForDelivery(_ value: AgentInput) throws -> JSONValue {
        let content = try value.codexContent()
        guard content.jsonString.utf8.count + 4096 <= StreamingProcess.maximumLineBytes else { throw AgentAttachmentError.tooLarge }
        return content
    }
    private func startTurn(content: JSONValue, mode: AgentMode) async throws {
        let owner = input
        var parameters: [String: JSONValue] = ["threadId": .string(session.nativeID),
            "input": content,
            "approvalPolicy": .string(mode.codexApproval),
            "sandboxPolicy": .object(["type": .string(mode == .plan ? "readOnly" : "workspaceWrite")])]
        if (content.arrayValue?.count ?? 0) > 1, let input {
            parameters["clientUserMessageId"] = .string(input.uuidString)
        }
        if let effort = configuration.effort { parameters["effort"] = .string(effort) }
        let result = try await wire.request("turn/start", .object(parameters))
        guard !closed, owner != nil, let native = result["turn"]?["id"]?.stringValue,
              input == owner || (input == nil && completedTurns.contains(native)) else {
            throw AgentFailure.invalidTransition
        }
        // A fast CLI can complete the turn before the RPC response is read.
        if !completedTurns.contains(native) { turn = native }
        self.mode = mode; emit(.modeChanged(mode)); acknowledge()
    }
    func receive(_ method: String, parameters p: JSONValue, requestID: AgentRequestID?) async {
        guard !closed else { return }
        if let requestID {
            guard input != nil, let nativeTurn = p["turnId"]?.stringValue,
                  !completedTurns.contains(nativeTurn), turn == nil || nativeTurn == turn, !seenRequests.contains(requestID), seenRequests.count < 100_000,
                  requests.count < 64 else {
                requests.removeValue(forKey: requestID)
                try? await wire.writeResponse(id: requestID, result: nil, error: true); return
            }
            seenRequests.insert(requestID)
            let kind: AgentRequest.Kind
            switch method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                var input = p.objectValue ?? [:]
                if let item = p["itemId"]?.stringValue, let changes = items[item]?["changes"] { input["changes"] = changes }
                kind = .permission(AgentTool(name: method == "item/commandExecution/requestApproval" ? "commandExecution" : "fileChange", input: .object(input)))
            case "item/permissions/requestApproval": kind = .permissions(p)
            case "item/tool/requestUserInput":
                guard let questions = try? agentQuestions(p["questions"] ?? .null, claude: false) else {
                    try? await wire.writeResponse(id: requestID, result: nil, error: true); return
                }
                kind = .questions(questions)
            default: try? await wire.writeResponse(id: requestID, result: nil, error: true); return
            }
            turn = nativeTurn
            let request = AgentRequest(id: requestID, scope: scope(item: p["itemId"]?.stringValue), kind: kind,
                                       isBlocking: p["isBlocking"]?.boolValue ?? true)
            requests[requestID] = request; emit(.request(request), item: request.scope.itemID)
            return
        }
        let nativeTurn = p["turnId"]?.stringValue ?? p["turn"]?["id"]?.stringValue
        if let nativeTurn {
            guard input != nil, !completedTurns.contains(nativeTurn), turn == nil || turn == nativeTurn else { return }
            turn = nativeTurn
        }
        let itemID = p["itemId"]?.stringValue ?? p["item"]?["id"]?.stringValue
        switch method {
        case "turn/started": acknowledge()
        case "item/agentMessage/delta": emit(.textDelta(p["delta"]?.stringValue ?? ""), item: itemID)
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta": emit(.thinkingDelta(p["delta"]?.stringValue ?? ""), item: itemID)
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta": emit(.toolOutput(p["delta"] ?? .null), item: itemID)
        case "item/started":
            let item = p["item"] ?? .null
            if let itemID { items[itemID] = item }
            if ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch"].contains(item["type"]?.stringValue ?? "") {
                emit(.toolStarted(AgentTool(name: item["type"]?.stringValue ?? "tool", input: item)), item: itemID)
            }
        case "item/completed": if let item = p["item"] { complete(item) }
        case "turn/plan/updated": emit(.planUpdated(p))
        case "thread/tokenUsage/updated":
            let usage = p["tokenUsage"] ?? .null, last = usage["last"] ?? .null
            emit(.usage(AgentUsage(scope: .lastCall, inputTokens: last["inputTokens"]?.int,
                outputTokens: last["outputTokens"]?.int, cachedInputTokens: last["cachedInputTokens"]?.int,
                cacheWriteInputTokens: last["cacheWriteInputTokens"]?.int, thinkingTokens: last["reasoningOutputTokens"]?.int,
                contextTokens: usage["total"]?["totalTokens"]?.int, contextLimit: usage["modelContextWindow"]?.int)))
        case "turn/completed":
            guard input != nil else { return }
            acknowledge()
            for item in p["turn"]?["items"]?.arrayValue ?? [] { complete(item) }
            let status = p["turn"]?["status"]?.stringValue
            let outcome: AgentTurnOutcome = status == "completed" ? .completed : status == "interrupted" ? .interrupted : .failed(.unknown)
            if let turn { completedTurns.insert(turn) }
            if mode == .plan, !executingApprovedPlan, outcome == .completed, let plan = proposedPlan,
               !plan.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A completed plan item is authoritative. Unlike turn/plan/updated,
                // this local review request authorizes a separate execution turn.
                let requestID = AgentRequestID.string("plan:\(turn ?? ""):\(plan.id)")
                let request = AgentRequest(id: requestID, scope: scope(item: plan.id), kind: .plan(plan.text))
                requests[requestID] = request; planRequestID = requestID
                emit(.request(request), item: plan.id)
                return
            }
            emit(.turnEnded(outcome)); input = nil; requests.removeAll()
        default: emit(.unknown(name: method, payload: p), item: itemID)
        }
    }
    private func complete(_ item: JSONValue) {
        guard let nativeID = item["id"]?.stringValue, completedItems.insert(nativeID).inserted else { return }
        items.removeValue(forKey: nativeID)
        switch item["type"]?.stringValue {
        case "plan":
            proposedPlan = (nativeID, item["text"]?.stringValue ?? "")
            emit(.message(id: nativeID, role: "assistant", text: item["text"]?.stringValue ?? ""), item: nativeID)
        case "agentMessage":
            let text = item["text"]?.stringValue ?? ""
            emit(.message(id: nativeID, role: "assistant", text: text), item: nativeID)
        case "userMessage":
            let text = (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            // Native user items may arrive for a steer while output remains
            // scoped to the original turn. Bind only an exact submitted input.
            let exact = userInputs.firstIndex { $0.id.uuidString == nativeID }
            let matchingText = userInputs.firstIndex {
                ([$0.text] + $0.attachments.filter { $0.kind == .text }.map(\.textBlock)).joined(separator: "\n") == text
            }
            guard let index = exact ?? matchingText else { return }
            let owner = userInputs.remove(at: index)
            continuation.yield(.init(scope: .init(runID: id, session: session, inputID: owner.id,
                turnID: turn, itemID: nativeID), kind: .message(id: nativeID, role: "user", text: text)))
        case "reasoning":
            let summary = (item["summary"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["text"]?.stringValue }.joined(separator: "\n")
            if !summary.isEmpty { emit(.thinkingCompleted(summary), item: nativeID) }
        case "fileChange":
            for change in item["changes"]?.arrayValue ?? [] {
                emit(.fileChanged(path: change["path"]?.stringValue ?? "", diff: change["diff"]?.stringValue ?? ""), item: nativeID)
            }
            emit(.toolFinished(output: item, isError: item["status"]?.stringValue == "failed"), item: nativeID)
        default: emit(.toolFinished(output: item["aggregatedOutput"] ?? item, isError: item["status"]?.stringValue == "failed"), item: nativeID)
        }
    }
    func respond(to request: AgentRequest, with response: AgentResponse) async throws {
        guard !closed, request.scope.runID == id, requests[request.id] == request else { throw AgentFailure.invalidRequest }
        if case .plan = request.kind, request.id == planRequestID {
            guard response == .allow(updatedInput: nil) || response == .deny else { throw AgentFailure.invalidRequest }
            requests.removeValue(forKey: request.id); planRequestID = nil
            if response == .deny {
                emit(.turnEnded(.completed)); input = nil
            } else {
                turn = nil; proposedPlan = nil; executingApprovedPlan = true
                // Approval is the user's instruction to continue this journaled
                // action; only the turn/start response acknowledges the new mode.
                do { try await startTurn(content: try AgentInput(text: "Implement the approved plan.").codexContent(), mode: .ask) }
                catch { emit(.turnEnded(.failed((error as? AgentFailure) ?? .unknown))); input = nil; throw error }
            }
            return
        }
        let result: JSONValue
        switch (request.kind, response) {
        case (.permission, .allow): result = .object(["decision": .string("accept")])
        case (.permission(let tool), .deny):
            let choices = tool.input["availableDecisions"]?.arrayValue?.compactMap(\.stringValue)
            result = .object(["decision": .string(choices == nil || choices!.contains("decline") ? "decline" : "cancel")])
        case (.permissions(let raw), .allow): result = .object(["permissions": raw["permissions"] ?? .object([:]), "scope": .string("turn")])
        case (.permissions, .deny): result = .object(["permissions": .object([:]), "scope": .string("turn")])
        case (.questions(let questions), .answers(let answers)):
            try AgentQuestionState.validate(answers, questions: questions)
            result = .object(["answers": .object(answers.mapValues { .object(["answers": .array($0.map(JSONValue.string))]) })])
        case (_, .unsupported): result = .null
        default: throw AgentFailure.invalidRequest
        }
        requests.removeValue(forKey: request.id)
        try await wire.writeResponse(id: request.id, result: result, error: response == .unsupported)
    }
    func setMode(_ mode: AgentMode) throws {
        guard !closed, input == nil else { throw AgentFailure.invalidTransition }
        self.mode = mode
    }
    func interrupt() async throws {
        guard !closed, input != nil, let turn else { throw AgentFailure.invalidTransition }
        if planRequestID != nil {
            requests.removeAll(); planRequestID = nil
            emit(.turnEnded(.interrupted)); input = nil
            return
        }
        requests.removeAll()
        _ = try await wire.request("turn/interrupt", .object(["threadId": .string(session.nativeID), "turnId": .string(turn)]), timeout: .seconds(1))
    }
    func resolved(_ requestID: AgentRequestID) {
        if requests.removeValue(forKey: requestID) != nil { emit(.requestResolved(requestID)) }
    }
    func rateLimits(_ windows: [AgentRateLimitWindow]) { emit(.rateLimits(windows)) }
    func disconnected(_ error: AgentFailure) {
        guard !closed else { return }
        closed = true; requests.removeAll()
        if input != nil { emit(.turnEnded(.failed(error))); input = nil }
        continuation.finish(throwing: error)
    }
    func abort() async {
        // One app-server hosts several threads. An unacknowledged interrupt
        // leaves execution uncertain: dispose it, expiring every affected run.
        try? await backend.shutdown()
    }
    func shutdown() async throws {
        guard !closed else { return }
        var failure: Error?
        if input != nil, turn != nil {
            do { try await interrupt() } catch { failure = error }
        }
        closed = true; input = nil; requests.removeAll(); continuation.finish()
        await backend.release(session, runID: id)
        if let failure { throw failure }
    }
}
