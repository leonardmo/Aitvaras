import Foundation

actor ClaudeRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let wire: AgentWire
    private let profile: String
    private var session: AgentSessionID?
    private var input: UUID?
    private var queue: [UUID] = []
    private var writing = false
    private var acknowledged = false
    private var interrupted = false
    private var assistantFailure: AgentFailure?
    private var closed = false
    private var modeState: AgentModeState
    private var requests: [AgentRequestID: (AgentRequest, JSONValue)] = [:]
    private var seenResults: Set<String> = []
    private var streamedThinking: Set<String> = []
    private var seenRequests: Set<AgentRequestID> = []
    private(set) var availableModels: [AgentModel] = []
    private(set) var availableCommands: [AgentCommand]?

    init(executable: URL, environment: [String: String], profile: String, configuration: AgentSessionConfiguration) {
        self.profile = profile; session = configuration.resume; modeState = AgentModeState(configuration.mode)
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode",
                         configuration.mode.claudePermission]
        if configuration.model != "default" { arguments += ["--model", configuration.model] }
        if let resume = configuration.resume { arguments += ["--resume", resume.nativeID] }
        if let effort = configuration.effort { arguments += ["--effort", effort] }
        if !configuration.instructions.isEmpty { arguments += ["--append-system-prompt", configuration.instructions] }
        wire = AgentWire(process: StreamingProcess(executable: executable, arguments: arguments,
            currentDirectory: configuration.directory, environment: environment), format: .claude)
        (events, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(4096))
    }

    func initialize() async throws {
        try await wire.open(receive: { [weak self] value, requestID in await self?.receive(value, requestID: requestID) },
                            disconnected: { [weak self] error in await self?.disconnected(error) })
        let hook: (String) -> JSONValue = { .array([.object(["matcher": .null, "hookCallbackIds": .array([.string($0)])])]) }
        let value = try await wire.request("initialize", .object(["hooks": .object([
            "PreToolUse": hook("pre"), "PostToolUse": hook("post")])]), id: .string("init"))
        if let source = value["account"]?["apiKeySource"], source.stringValue != "none" { throw AgentFailure.unsupported }
        availableCommands = try? AgentCommandCatalog.claude(value)
        availableModels = (value["models"]?.arrayValue ?? []).compactMap {
            guard let id = $0["value"]?.stringValue else { return nil }
            return AgentModel(id: id, name: $0["displayName"]?.stringValue ?? id,
                              efforts: $0["supportedEffortLevels"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }
    }

    private func scope(item: String? = nil) -> AgentEventScope {
        AgentEventScope(runID: id, session: session, inputID: input, itemID: item)
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
    func send(_ value: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed, input == nil, !writing else { throw AgentFailure.invalidTransition }
        let frame = try userFrame(value, followup: false)
        input = value.id; acknowledged = false; interrupted = false; assistantFailure = nil; streamedThinking.removeAll(); streamTools.removeAll(); streamTexts.removeAll(); streamingMessageID = nil
        do { try await willDeliver() } catch { input = nil; throw error }
        guard !closed, input == value.id, !interrupted else { throw AgentFailure.invalidTransition }
        emit(.delivery(.deliveryUnknown))
        try await wire.write(frame)
    }
    func followup(_ value: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed, !interrupted, input != nil, !writing,
              input != value.id, !queue.contains(value.id), queue.count < 32 else { throw AgentFailure.invalidTransition }
        let frame = try userFrame(value, followup: true)
        writing = true
        defer { writing = false }
        try await willDeliver()
        guard !closed, !interrupted, input != nil else { throw AgentFailure.invalidTransition }
        queue.append(value.id)
        continuation.yield(.init(scope: .init(runID: id, session: session, inputID: value.id), kind: .delivery(.deliveryUnknown)))
        try await wire.write(frame)
    }
    private func userFrame(_ value: AgentInput, followup: Bool) throws -> JSONValue {
        var frame: [String: JSONValue] = ["type": .string("user"), "message": .object([
            "role": .string("user"), "content": try value.claudeContent()])]
        if followup { frame["uuid"] = .string(value.id.uuidString) }
        let result = JSONValue.object(frame)
        guard result.jsonString.utf8.count <= StreamingProcess.maximumLineBytes else { throw AgentAttachmentError.tooLarge }
        return result
    }
    private func activateNext() {
        guard !interrupted, !queue.isEmpty else { return }
        input = queue.removeFirst(); acknowledged = false; assistantFailure = nil
        streamedThinking.removeAll(); streamTools.removeAll(); streamTexts.removeAll(); streamingMessageID = nil
        emit(.inputActivated)
    }
    private func acknowledge() {
        if input != nil, !acknowledged { acknowledged = true; emit(.delivery(.acknowledged)) }
    }

    private func receive(_ value: JSONValue, requestID: AgentRequestID?) async {
        guard !closed else { return }
        if let native = value["session_id"]?.stringValue, session == nil {
            session = AgentSessionID(provider: .claude, profile: profile, nativeID: native)
            emit(.sessionStarted(session!))
        }
        switch value["type"]?.stringValue {
        case "system" where value["subtype"]?.stringValue == "init":
            if value["apiKeySource"]?.stringValue != "none" { await disconnected(.unsupported) }
        case "control_request":
            guard let requestID, case .string = requestID, let raw = value["request"] else { await disconnected(.invalidRequest); return }
            guard !seenRequests.contains(requestID), seenRequests.count < 100_000 else { await disconnected(.invalidRequest); return }
            seenRequests.insert(requestID)
            guard input != nil else { try? await controlReply(requestID, payload: .null, error: true); return }
            let kind: AgentRequest.Kind
            let tool = AgentTool(name: raw["tool_name"]?.stringValue ?? "", input: raw["input"] ?? .object([:]))
            if raw["subtype"]?.stringValue == "hook_callback" {
                let hookInput = raw["input"] ?? .null
                let tool = AgentTool(name: hookInput["tool_name"]?.stringValue ?? "", input: hookInput["tool_input"] ?? .null)
                if raw["callback_id"]?.stringValue == "pre", hookInput["hook_event_name"]?.stringValue == "PreToolUse" {
                    kind = .preToolUse(tool)
                } else if raw["callback_id"]?.stringValue == "post", hookInput["hook_event_name"]?.stringValue == "PostToolUse" {
                    kind = .postToolUse(tool, output: hookInput["tool_response"] ?? .null)
                    if tool.name == "ExitPlanMode", hookInput["permission_mode"]?.stringValue == "default",
                       modeState.acknowledgePlan(itemID: raw["tool_use_id"]?.stringValue) {
                        emit(.modeChanged(.ask))
                    }
                } else { try? await controlReply(requestID, payload: .null, error: true); return }
            } else if raw["subtype"]?.stringValue == "can_use_tool", !tool.name.isEmpty {
                switch tool.name {
                case "ExitPlanMode":
                    guard let plan = tool.input["plan"]?.stringValue,
                          !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        try? await controlReply(requestID, payload: .null, error: true); return
                    }
                    kind = .plan(plan)
                case "AskUserQuestion":
                    guard let questions = try? agentQuestions(tool.input["questions"] ?? .null, claude: true) else {
                        try? await controlReply(requestID, payload: .null, error: true); return
                    }
                    kind = .questions(questions)
                default: kind = .permission(tool)
                }
            } else { try? await controlReply(requestID, payload: .null, error: true); return }
            let request = AgentRequest(id: requestID, scope: scope(item: raw["tool_use_id"]?.stringValue), kind: kind)
            guard requests.count < 64 else { await disconnected(.invalidRequest); return }
            requests[requestID] = (request, raw)
            emit(.request(request), item: request.scope.itemID)
        case "control_cancel_request":
            if let requestID { requests.removeValue(forKey: requestID); modeState.cancel(); emit(.requestResolved(requestID)) }
        case "stream_event":
            acknowledge()
            parseStream(value["event"] ?? .null)
        case "assistant", "user":
            acknowledge()
            if let error = value["error"]?.stringValue { assistantFailure = error == "authentication_failed" ? .authRequired : .unknown }
            parseMessage(value)
        case "rate_limit_event": emit(.rateLimits(claudeRateLimits(value["rate_limit_info"] ?? .null)))
        case "result":
            if let nativeID = value["uuid"]?.stringValue, !seenResults.insert(nativeID).inserted { return }
            guard input != nil else { return }
            let usage = value["usage"] ?? .null
            emit(.usage(AgentUsage(scope: .turn, inputTokens: usage["input_tokens"]?.int,
                outputTokens: usage["output_tokens"]?.int, cachedInputTokens: usage["cache_read_input_tokens"]?.int,
                cacheWriteInputTokens: usage["cache_creation_input_tokens"]?.int,
                thinkingTokens: usage["output_tokens_details"]?["thinking_tokens"]?.int, costUSD: value["total_cost_usd"]?.doubleValue)))
            // Interrupt results can also contain an assistant execution error.
            // That error must not turn a user Stop into an unknown failure.
            let aborted = value["terminal_reason"]?.stringValue == "aborted_streaming"
            let outcome: AgentTurnOutcome = (interrupted || aborted)
                ? .interrupted : assistantFailure.map { .failed($0) }
                    ?? (value["is_error"]?.boolValue == false ? .completed : .failed(.unknown))
            emit(.turnEnded(outcome)); input = nil; requests.removeAll(); modeState.cancel()
            activateNext()
        default: emit(.unknown(name: value["type"]?.stringValue ?? "unknown", payload: value))
        }
    }

    func respond(to request: AgentRequest, with response: AgentResponse) async throws {
        guard !closed, request.scope.runID == id, let (stored, raw) = requests[request.id], stored == request else {
            throw AgentFailure.invalidRequest
        }
        let isHook = raw["subtype"]?.stringValue == "hook_callback"
        let payload: JSONValue
        switch response {
        case .continueHook where isHook: payload = .object(["continue": .bool(true)])
        case .deny where isHook:
            payload = .object(["continue": .bool(false), "stopReason": .string("Action denied")])
        case .allow(let updated) where !isHook:
            payload = .object(["behavior": .string("allow"), "updatedInput": updated ?? raw["input"] ?? .object([:])])
        case .deny where !isHook:
            payload = .object(["behavior": .string("deny"), "message": .string("Action denied")])
        case .answers(let answers) where !isHook:
            guard case .questions(let questions) = request.kind else { throw AgentFailure.invalidRequest }
            try AgentQuestionState.validate(answers, questions: questions)
            var updated = raw["input"]?.objectValue ?? [:]
            updated["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
            payload = .object(["behavior": .string("allow"), "updatedInput": .object(updated)])
        case .unsupported: payload = .null
        default: throw AgentFailure.invalidRequest
        }
        requests.removeValue(forKey: request.id)
        if case .plan = request.kind, case .allow = response { modeState.approve(request) }
        try await controlReply(request.id, payload: payload, error: response == .unsupported)
    }
    private func controlReply(_ id: AgentRequestID, payload: JSONValue, error: Bool) async throws {
        var response: [String: JSONValue] = ["subtype": .string(error ? "error" : "success"), "request_id": id.json]
        response[error ? "error" : "response"] = error ? .string("Unsupported request") : payload
        try await wire.write(.object(["type": .string("control_response"), "response": .object(response)]))
    }
    func setMode(_ mode: AgentMode) async throws {
        guard !closed, input == nil else { throw AgentFailure.invalidTransition }
        _ = try await wire.request("set_permission_mode", .object(["mode": .string(mode.claudePermission)]))
        guard !closed else { throw AgentFailure.invalidTransition }
        modeState.acknowledge(mode); emit(.modeChanged(mode))
    }
    func interrupt() async throws {
        guard !closed, input != nil else { throw AgentFailure.invalidTransition }
        interrupted = true; requests.removeAll()
        _ = try await wire.request("interrupt", timeout: .seconds(1))
    }
    func disconnected(_ error: AgentFailure) async {
        guard !closed else { return }
        closed = true; requests.removeAll()
        if input != nil { emit(.turnEnded(.failed(error))); input = nil }
        continuation.finish(throwing: error)
        Task { try? await wire.close() }
    }
    func abort() async {
        closed = true; input = nil; queue.removeAll(); requests.removeAll(); continuation.finish()
        try? await wire.close()
    }
    func shutdown() async throws {
        if !closed { closed = true; requests.removeAll(); continuation.finish(); input = nil }
        try await wire.close()
    }

    private var streamingMessageID: String?
    private var streamTools: [Int: String] = [:]
    private var streamTexts: [Int: String] = [:]
    private func parseStream(_ event: JSONValue) {
        let type = event["type"]?.stringValue
        if type == "message_start" {
            streamingMessageID = event["message"]?["id"]?.stringValue
            streamTools.removeAll(); streamTexts.removeAll()
        }
        let index = event["index"]?.int ?? 0
        if type == "content_block_start", let block = event["content_block"] {
            if block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue {
                streamTools[index] = id
                emit(.toolStarted(.init(name: block["name"]?.stringValue ?? "Tool", input: block["input"] ?? .null)), item: id)
            }
            if block["type"]?.stringValue == "text" {
                if !streamTexts.isEmpty { emit(.textDelta("\n"), item: streamingMessageID) }
                let text = block["text"]?.stringValue ?? ""
                streamTexts[index] = text
                if !text.isEmpty { emit(.textDelta(text), item: streamingMessageID) }
            }
        }
        if type == "content_block_delta" {
            let delta = event["delta"] ?? .null
            if let text = delta["text"]?.stringValue {
                streamTexts[index, default: ""] += text
                emit(.textDelta(text), item: streamingMessageID)
            }
            if let thinking = delta["thinking"]?.stringValue {
                if let streamingMessageID { streamedThinking.insert(streamingMessageID) }
                emit(.thinkingDelta(thinking), item: streamingMessageID)
            }
            if let partial = delta["partial_json"]?.stringValue, let id = streamTools[index] {
                emit(.toolInputDelta(partial), item: id)
            }
        }
    }
    private func parseMessage(_ value: JSONValue) {
        let message = value["message"] ?? .null
        let messageID = message["id"]?.stringValue ?? value["uuid"]?.stringValue
        var texts: [String] = []
        for block in message["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text": if let text = block["text"]?.stringValue { texts.append(text) }
            case "thinking":
                if messageID == nil || !streamedThinking.contains(messageID!) {
                    emit(.thinkingDelta(block["thinking"]?.stringValue ?? ""), item: messageID)
                }
            case "tool_use": emit(.toolStarted(AgentTool(name: block["name"]?.stringValue ?? "", input: block["input"] ?? .null)), item: block["id"]?.stringValue)
            case "tool_result": emit(.toolFinished(output: block["content"] ?? .null, isError: block["is_error"]?.boolValue ?? false), item: block["tool_use_id"]?.stringValue)
            default: emit(.unknown(name: block["type"]?.stringValue ?? "content", payload: block), item: messageID)
            }
        }
        if let messageID, !texts.isEmpty { emit(.message(id: messageID, role: message["role"]?.stringValue ?? "assistant", text: messageID == streamingMessageID && !streamTexts.isEmpty
            ? streamTexts.keys.sorted().compactMap { streamTexts[$0] }.joined(separator: "\n")
            : texts.joined(separator: "\n")), item: messageID) }
    }
}

extension AgentMode {
    var claudePermission: String { self == .ask ? "default" : rawValue }
}

func claudeRateLimits(_ value: JSONValue) -> [AgentRateLimitWindow] {
    (value["unifiedWindows"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { key, window in
        AgentRateLimitWindow(id: key, utilization: window["utilization"]?.doubleValue.map { min(1, max(0, $0)) },
            duration: key == "five_hour" ? 5 * 3600 : key == "seven_day" ? 7 * 86400 : nil,
            resetsAt: window["resetsAt"]?.date)
    }
}
