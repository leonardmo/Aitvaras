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
    private var acknowledged = false
    private var closed = false
    private var requests: [AgentRequestID: AgentRequest] = [:]
    private var seenRequests: Set<AgentRequestID> = []
    private var completedTurns: Set<String> = []
    private var completedItems: Set<String> = []

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
        input = value.id; turn = nil; acknowledged = false; completedItems.removeAll()
        do { try await willDeliver() } catch { input = nil; throw error }
        guard !closed else { throw AgentFailure.invalidTransition }
        var parameters: [String: JSONValue] = ["threadId": .string(session.nativeID),
            "input": .array([.object(["type": .string("text"), "text": .string(value.text)])]),
            "approvalPolicy": .string(mode.codexApproval),
            "sandboxPolicy": .object(["type": .string(mode == .plan ? "readOnly" : "workspaceWrite")])]
        if let effort = configuration.effort { parameters["effort"] = .string(effort) }
        emit(.delivery(.deliveryUnknown))
        do {
            let result = try await wire.request("turn/start", .object(parameters))
            if input == value.id { turn = result["turn"]?["id"]?.stringValue; acknowledge() }
        } catch {
            if input == value.id { emit(.turnEnded(.failed((error as? AgentFailure) ?? .unknown))); input = nil; requests.removeAll() }
            throw error
        }
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
                kind = .permission(AgentTool(name: method == "item/commandExecution/requestApproval" ? "commandExecution" : "fileChange", input: p))
            case "item/permissions/requestApproval": kind = .permissions(p)
            case "item/tool/requestUserInput": kind = .questions(agentQuestions(p["questions"] ?? .null, claude: false))
            default: try? await wire.writeResponse(id: requestID, result: nil, error: true); return
            }
            turn = nativeTurn
            let request = AgentRequest(id: requestID, scope: scope(item: p["itemId"]?.stringValue), kind: kind)
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
            emit(.turnEnded(outcome)); input = nil; requests.removeAll()
        default: emit(.unknown(name: method, payload: p), item: itemID)
        }
    }
    private func complete(_ item: JSONValue) {
        guard let nativeID = item["id"]?.stringValue, completedItems.insert(nativeID).inserted else { return }
        switch item["type"]?.stringValue {
        case "agentMessage": emit(.message(id: nativeID, role: "assistant", text: item["text"]?.stringValue ?? ""), item: nativeID)
        case "userMessage":
            let text = (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            emit(.message(id: nativeID, role: "user", text: text), item: nativeID)
        case "reasoning":
            for block in item["summary"]?.arrayValue ?? [] { emit(.thinkingDelta(block.stringValue ?? block["text"]?.stringValue ?? ""), item: nativeID) }
        case "fileChange":
            for change in item["changes"]?.arrayValue ?? [] {
                emit(.fileChanged(path: change["path"]?.stringValue ?? "", diff: change["diff"]?.stringValue ?? ""), item: nativeID)
            }
            emit(.toolFinished(output: item, isError: item["status"]?.stringValue == "failed"), item: nativeID)
        default: emit(.toolFinished(output: item, isError: item["status"]?.stringValue == "failed"), item: nativeID)
        }
    }
    func respond(to request: AgentRequest, with response: AgentResponse) async throws {
        guard !closed, request.scope.runID == id, requests[request.id] == request else { throw AgentFailure.invalidRequest }
        let result: JSONValue
        switch (request.kind, response) {
        case (.permission, .allow): result = .object(["decision": .string("accept")])
        case (.permission, .deny): result = .object(["decision": .string("decline")])
        case (.permissions(let raw), .allow): result = .object(["permissions": raw["permissions"] ?? .object([:]), "scope": .string("turn")])
        case (.permissions, .deny): result = .object(["permissions": .object([:]), "scope": .string("turn")])
        case (.questions(let questions), .answers(let answers)):
            guard Set(answers.keys) == Set(questions.map(\.id)) else { throw AgentFailure.invalidRequest }
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
        requests.removeAll()
        _ = try await wire.request("turn/interrupt", .object(["threadId": .string(session.nativeID), "turnId": .string(turn)]))
    }
    func resolved(_ requestID: AgentRequestID) { requests.removeValue(forKey: requestID) }
    func rateLimits(_ windows: [AgentRateLimitWindow]) { emit(.rateLimits(windows)) }
    func disconnected(_ error: AgentFailure) {
        guard !closed else { return }
        closed = true; requests.removeAll()
        if input != nil { emit(.turnEnded(.failed(error))); input = nil }
        continuation.finish(throwing: error)
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
