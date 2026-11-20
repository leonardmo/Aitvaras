import Foundation

actor ClaudeRun: AgentRun {
    nonisolated let id: UUID
    nonisolated let accountID: String?
    nonisolated let mcpSetup: AgentMCPLaunchStatus?
    nonisolated let permissionSource: AgentPermissionSource
    private let validateProjectServers: @Sendable (JSONValue) async throws -> Void
    private let metadataReader: AgentProjectMetadataReader
    private(set) var availableSetup = AgentSetupSnapshot(provider: .claude)
    private var hookPhases: [String: AgentHookEvent.Phase] = [:]
    private var runtimeFile: AgentMCPRuntimeFile?
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let wire: AgentWire
    private var hasGateway = false
    private let profile: String
    private var session: AgentSessionID?
    private let forkSource: AgentSessionID?
    private var input: UUID?
    private var queue: [UUID] = []
    // A queued command can be echoed after the model's result has drained the queue.
    private var recentCommands: [UUID] = []
    private var localCommand: (id: UUID, nativeID: String, text: String, caveat: Bool, output: String?)?
    private var pendingCommandCaveat = false
    private var modelWorked = false
    private var writing = false
    private var acknowledged = false
    private var interrupted = false
    private var assistantFailure: AgentFailure?
    private var usageFailure: AgentFailure?
    private var closed = false
    private var terminalFailure: AgentFailure?
    private let verifiesResumeIdentity: Bool
    private var modeState: AgentModeState
    private var requests: [AgentRequestID: (AgentRequest, JSONValue)] = [:]
    private var seenResults: Set<String> = []
    private var seenMessages: Set<String>
    private var autonomous = false
    private var lastAutonomousReason: AgentAutonomousReason = .unknown
    private var streamedThinking: Set<String> = []
    private var seenRequests: Set<AgentRequestID> = []
    private(set) var availableModels: [AgentModel] = []
    private(set) var availableCommands: [AgentCommand]?

    init(executable: URL, environment: [String: String], profile: String, configuration: AgentSessionConfiguration,
         id: UUID = UUID(), accountID: String? = nil, runtimeFile: AgentMCPRuntimeFile? = nil, mcpSetup: AgentMCPLaunchStatus? = nil,
         permissionSource: AgentPermissionSource = .repo, metadataReader: AgentProjectMetadataReader? = nil,
         validateProjectServers: @escaping @Sendable (JSONValue) async throws -> Void) {
        self.accountID = accountID
        self.validateProjectServers = validateProjectServers
        self.id = id; self.runtimeFile = runtimeFile; self.mcpSetup = mcpSetup
        self.permissionSource = permissionSource
        self.metadataReader = metadataReader ?? AgentProjectMetadataReader(projectDirectory: configuration.directory)
        seenMessages = configuration.knownMessageIDs
        self.profile = profile; session = configuration.forkSession ? nil : configuration.resume; modeState = AgentModeState(configuration.mode)
        verifiesResumeIdentity = configuration.verifiesResumeIdentity
        forkSource = configuration.forkSession ? configuration.resume : nil
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode",
                         configuration.mode.claudePermission]
        for root in configuration.additionalDirectories { arguments += ["--add-dir", root.path] }
        arguments += ["--model", ChatSettings.claudeModel(configuration.model)]
        if let resume = configuration.resume { arguments += ["--resume", resume.nativeID] }
        if configuration.forkSession { arguments += ["--fork-session"] }
        if let message = configuration.resumeSessionAt { arguments += ["--resume-session-at", message] }
        arguments += ["--effort", ChatSettings.claudeEffort(configuration.effort)]
        if !configuration.instructions.isEmpty { arguments += ["--append-system-prompt", configuration.instructions] }
        if let settings = configuration.settingsJSON { arguments += ["--settings", settings] }
        if let file = configuration.mcpConfigPath { arguments += ["--mcp-config", file.path] }
        if configuration.includeHookEvents { arguments += ["--include-hook-events"] }
        if configuration.strictMCPConfig { arguments += ["--strict-mcp-config"] }
        wire = AgentWire(process: StreamingProcess(executable: executable, arguments: arguments,
            currentDirectory: configuration.directory, environment: environment), format: .claude)
        (events, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(4096))
    }

    func initialize(register: AgentWire.RegisterProcess? = nil) async throws {
        availableSetup.metadata = await metadataReader.read()
        hasGateway = register != nil
        try await wire.open(receive: { [weak self] value, requestID in await self?.receive(value, requestID: requestID) },
                            disconnected: { [weak self] error in await self?.disconnected(error) }, register: register)
        let hook: (String) -> JSONValue = { .array([.object(["matcher": .null, "hookCallbackIds": .array([.string($0)])])]) }
        let value: JSONValue
        do {
            value = try await wire.request("initialize", .object(["hooks": .object([
                "PreToolUse": hook("pre"), "PostToolUse": hook("post")])]), id: .string("init"))
        } catch { throw terminalFailure ?? error }
        guard !closed else { throw terminalFailure ?? AgentFailure.invalidTransition }
        if let source = value["account"]?["apiKeySource"], source.stringValue != "none" { throw AgentFailure.unsupported }
        availableCommands = try? AgentCommandCatalog.claude(value)
        availableSetup.initialize(value)
        if availableSetup.commandsAvailable { availableCommands = availableSetup.commands }
        emit(.setupReported(availableSetup))
        availableModels = ChatSettings.claudeModels((value["models"]?.arrayValue ?? []).compactMap {
            guard let id = $0["value"]?.stringValue else { return nil }
            return AgentModel(id: id, name: $0["displayName"]?.stringValue ?? id,
                              efforts: $0["supportedEffortLevels"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        })
    }

    var canRefreshSetup: Bool { !closed }
    func refreshSetup() async throws -> AgentSetupSnapshot {
        guard !closed else { throw AgentFailure.invalidTransition }
        let response = try await wire.request("mcp_status", timeout: .seconds(5), failOnTimeout: false)
        guard !closed else { throw terminalFailure ?? AgentFailure.invalidTransition }
        var snapshot = availableSetup
        try snapshot.claudeMCPStatus(response)
        // Status is an inventory response, which may include disabled entries.
        // The launch gate and system/init validation decide execution authority.
        availableSetup = snapshot
        emit(.setupReported(snapshot))
        return snapshot
    }

    private func scope(item: String? = nil) -> AgentEventScope {
        AgentEventScope(runID: id, session: session, inputID: input, itemID: item)
    }
    private func emit(_ kind: AgentEvent.Kind, item: String? = nil, report: AgentFailureReport? = nil) {
        switch continuation.yield(AgentEvent(scope: scope(item: item), kind: kind, failureReport: report)) {
        case .enqueued: break
        case .dropped, .terminated:
            continuation.finish(throwing: AgentFailure.invalidTransition)
            Task { try? await self.shutdown() }
        @unknown default: break
        }
    }
    func send(_ value: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed, input == nil, !writing else { throw AgentFailure.invalidTransition }
        let frame = try userFrame(value)
        autonomous = false
        input = value.id; acknowledged = false; interrupted = false; assistantFailure = nil; usageFailure = nil; streamedThinking.removeAll(); streamTools.removeAll(); streamTexts.removeAll(); streamingMessageID = nil
        do { try await willDeliver() } catch { input = nil; throw error }
        guard !closed, input == value.id, !interrupted else { throw AgentFailure.invalidTransition }
        modelWorked = false
        rememberCommand(value)
        emit(.delivery(.deliveryUnknown))
        try await wire.write(frame)
    }
    func followup(_ value: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed, !interrupted, input != nil, !writing,
              input != value.id, !queue.contains(value.id), queue.count < 32 else { throw AgentFailure.invalidTransition }
        let frame = try userFrame(value)
        writing = true
        defer { writing = false }
        try await willDeliver()
        guard !closed, !interrupted, input != nil else { throw AgentFailure.invalidTransition }
        queue.append(value.id)
        rememberCommand(value)
        continuation.yield(.init(scope: .init(runID: id, session: session, inputID: value.id), kind: .delivery(.deliveryUnknown)))
        try await wire.write(frame)
    }
    private func rememberCommand(_ input: AgentInput) {
        guard input.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else { return }
        recentCommands.append(input.id)
        if recentCommands.count > 64 { recentCommands.removeFirst() }
    }

    /// Consume local records before any of them can trigger autonomous work or
    /// acknowledge the unrelated model turn that happens to be active.
    private func receiveCommand(_ record: JSONValue, type: String) -> Bool {
        if ClaudeCommandText.isCaveat(record) { pendingCommandCaveat = true; return true }
        if type == "user", let nativeID = record["uuid"]?.stringValue, let id = UUID(uuidString: nativeID),
           recentCommands.contains(id), let text = ClaudeCommandText.messageText(record["message"]?["content"]),
           let command = ClaudeCommandText.command(in: text) {
            localCommand = (id, nativeID, command, pendingCommandCaveat, nil)
            pendingCommandCaveat = false
            if id == input { acknowledge() }
            if id == input || queue.contains(id) {
                let owner = AgentEventScope(runID: self.id, session: session, inputID: id, itemID: nativeID)
                if id != input { continuation.yield(.init(scope: owner, kind: .delivery(.acknowledged))) }
                continuation.yield(.init(scope: owner, kind: .message(id: nativeID, role: "user", text: command)))
            }
            return true
        }
        if type == "user", let nativeID = record["uuid"]?.stringValue, let id = UUID(uuidString: nativeID),
           id == input || queue.contains(id) {
            // A person's literal stdout tag is ordinary input.
            pendingCommandCaveat = false; localCommand = nil
            return false
        }
        let synthetic = type == "assistant" && localCommand?.caveat == true && localCommand?.output == nil
            && record["error"] == nil && record["message"]?["model"]?.stringValue == "<synthetic>"
        if type == "result", record["num_turns"]?.int == 0, record["is_error"]?.boolValue == false,
           let command = localCommand, command.id != input, let output = command.output,
           let result = record["result"]?.stringValue, !result.isEmpty,
           output == result || output.hasPrefix(result + "\n") { return true }
        let output = ClaudeCommandText.output(in: record)
            ?? (synthetic ? ClaudeCommandText.messageText(record["message"]?["content"]) : nil)
        guard let output else { return false }
        guard var command = localCommand else {
            // System output may be replayed without its command.
            return type == "system" || type == "user"
        }
        if type != "result" || command.output == nil {
            let combined = command.output.map { $0 + "\n" + output } ?? output
            command.output = combined
            localCommand = command
            let owner = AgentEventScope(runID: id, session: session, inputID: command.id, itemID: command.nativeID)
            continuation.yield(.init(scope: owner, kind: .claudeCommandResult(
                id: command.nativeID, command: command.text, output: combined)))
            if command.id == input { acknowledged = true }
            else { queue.removeAll { $0 == command.id } }
        }
        return type != "result" || command.id != input
    }

    private func userFrame(_ value: AgentInput) throws -> JSONValue {
        var frame: [String: JSONValue] = ["type": .string("user"), "message": .object([
            "role": .string("user"), "content": try value.claudeContent()])]
        // The persisted JSONL uses this UUID as the canonical user identity.
        frame["uuid"] = .string(value.id.uuidString)
        let result = JSONValue.object(frame)
        guard result.jsonString.utf8.count <= StreamingProcess.maximumLineBytes else { throw AgentAttachmentError.tooLarge }
        return result
    }
    private func acknowledge() {
        if input != nil, !acknowledged { acknowledged = true; emit(.delivery(.acknowledged)) }
    }

    private func receive(_ value: JSONValue, requestID: AgentRequestID?) async {
        guard !closed else { return }
        if let native = value["session_id"]?.stringValue, session == nil {
            if let source = forkSource, UUID(uuidString: native) == nil || UUID(uuidString: native) == UUID(uuidString: source.nativeID) {
                await disconnected(.invalidRequest); return
            }
            session = AgentSessionID(provider: .claude, profile: profile, nativeID: native)
            emit(.sessionStarted(session!))
        }
        let type = value["type"]?.stringValue ?? ""
        if value["isReplay"]?.boolValue == true { return }
        if ["assistant", "user"].contains(type) || (type == "system" && ClaudeCommandText.output(in: value) != nil) {
            if let uuid = value["uuid"]?.stringValue, !seenMessages.insert(uuid).inserted { return }
        }
        if type == "result", let nativeID = value["uuid"]?.stringValue, !seenResults.insert(nativeID).inserted { return }
        if receiveCommand(value, type: type) { return }
        if type == "user", injectedReason(value) == .backgroundTask {
            let content = value["message"]?["content"] ?? .null
            let text = content.stringValue ?? hookOutputStrings(content).joined(separator: "\n")
            if let start = text.range(of: "<task-id>"), let end = text.range(of: "</task-id>", range: start.upperBound..<text.endIndex) {
                emit(.unknown(name: "backgroundTaskFinished", payload: .string(String(text[start.upperBound..<end.lowerBound]))))
            }
        }
        // Only actual work starts a turn. Inventories, hook status and results
        // on their own cannot turn resumed history into a fresh response.
        let startsTurn = ["stream_event", "assistant", "control_request"].contains(type)
            || (type == "user" && injectedReason(value) != nil)
        if input == nil, startsTurn {
            let reason = injectedReason(value) ?? lastAutonomousReason
            modelWorked = false
            input = UUID(); autonomous = true; acknowledged = false; interrupted = false; assistantFailure = nil; usageFailure = nil
            streamedThinking.removeAll(); streamTools.removeAll(); streamTexts.removeAll(); streamingMessageID = nil
            emit(.autonomousTurnStarted(input!, reason))
            emit(.delivery(.deliveryUnknown))
        }
        switch value["type"]?.stringValue {
        case "system" where value["subtype"]?.stringValue == "init":
            if verifiesResumeIdentity, let native = value["session_id"]?.stringValue {
                // Let the manager's expectedNative check validate Continue.
                // Tool, subagent, hook and compaction frames are not identity.
                emit(.sessionStarted(.init(provider: .claude, profile: profile, nativeID: native)))
            }
            if value["apiKeySource"]?.stringValue != "none" { await disconnected(.unsupported); return }
            do {
                // The CLI has consumed the file; retain only the in-memory
                // redaction cache for subsequent hook diagnostics.
                try await runtimeFile?.remove(preservingRedactions: true)
                try await validateProjectServers(value)
            } catch {
                await disconnected((error as? AgentFailure) ?? .unapprovedProjectMCP); return
            }
            guard !closed else { return }
            availableSetup.claudeInit(value)
            if availableSetup.commandsAvailable { availableCommands = availableSetup.commands }
            emit(.setupReported(availableSetup))
        case "system" where ["hook_started", "hook_response"].contains(value["subtype"]?.stringValue):
            await parseHook(value)
        case "system" where value["subtype"]?.stringValue == "task_notification":
            if let taskID = value["task_id"]?.stringValue,
               ["completed", "failed", "stopped"].contains(value["status"]?.stringValue ?? "") {
                lastAutonomousReason = .backgroundTask
                emit(.unknown(name: "backgroundTaskFinished", payload: .string(taskID)))
            }
        case "system": break
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
            modelWorked = true
            acknowledge()
            parseStream(value["event"] ?? .null)
        case "assistant", "user":
            if type == "assistant" { modelWorked = true }
            acknowledge()
            if let error = value["error"]?.stringValue {
                if error == "authentication_failed" { assistantFailure = .authRequired }
                else if ["rate_limit", "rate_limit_error", "usage_limit", "usage_limit_reached"].contains(error) {
                    usageFailure = usageFailure ?? .quota(resetsAt: nil)
                } else { assistantFailure = .providerError }
            }
            // Injected reminders are provenance for the marker, never a user bubble.
            if !(autonomous && type == "user" && injectedReason(value) != nil) { await parseMessage(value) }
        case "rate_limit_event":
            let info = value["rate_limit_info"] ?? .null
            let evidence = AgentUsageLimit.claude(info)
            emit(.rateLimits(claudeRateLimits(info)))
            emit(.usageLimit(evidence))
            if input != nil, evidence.status == .rejected { usageFailure = .quota(resetsAt: evidence.resetsAt) }
        case "result":
            guard let owner = input else { return }
            if hasGateway {
                await wire.cancelGatewayApprovals()
                guard !closed, input == owner else { return }
            }
            if modelWorked || localCommand?.id != input || localCommand?.output == nil {
                let usage = value["usage"] ?? .null
                emit(.usage(AgentUsage(scope: .turn, inputTokens: usage["input_tokens"]?.int,
                    outputTokens: usage["output_tokens"]?.int, cachedInputTokens: usage["cache_read_input_tokens"]?.int,
                    cacheWriteInputTokens: usage["cache_creation_input_tokens"]?.int,
                    thinkingTokens: usage["output_tokens_details"]?["thinking_tokens"]?.int, costUSD: value["total_cost_usd"]?.doubleValue)))
            }
            // Interrupt results can also contain an assistant execution error.
            // That error must not turn a user Stop into an unknown failure.
            let aborted = value["terminal_reason"]?.stringValue == "aborted_streaming"
            let outcome: AgentTurnOutcome = (interrupted || aborted)
                ? .interrupted : (assistantFailure == .authRequired ? assistantFailure : usageFailure ?? assistantFailure).map { .failed($0) }
                    ?? (value["is_error"]?.boolValue == false ? .completed : .failed(.providerError))
            let completed = [input!] + queue
            continuation.yield(.init(scope: .init(runID: id, session: session, inputID: input,
                completedInputIDs: completed.count > 1 ? completed : []), kind: .turnEnded(outcome)))
            input = nil; autonomous = false; queue.removeAll(); requests.removeAll(); modeState.cancel()
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
        case .askHook where isHook && raw["callback_id"]?.stringValue == "pre":
            payload = .object(["hookSpecificOutput": .object(["hookEventName": .string("PreToolUse"), "permissionDecision": .string("ask")])])
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
        guard !closed, let owner = input else { throw AgentFailure.invalidTransition }
        interrupted = true; requests.removeAll()
        if hasGateway {
            await wire.cancelGatewayApprovals()
            guard !closed, input == owner else { return }
        }
        _ = try await wire.request("interrupt", timeout: .seconds(1))
    }
    func disconnected(_ error: AgentFailure) async {
        await disconnected(AgentFailureDiagnostics.capture(error))
    }
    func disconnected(_ error: AgentFailureReport) async {
        guard !closed else { return }
        closed = true; terminalFailure = error.failure; requests.removeAll()
        if input != nil { emit(.turnEnded(.failed(error.failure)), report: error); input = nil }
        continuation.finish(throwing: error.failure)
        await closeTransport()
    }
    func abort() async {
        closed = true; input = nil; queue.removeAll(); requests.removeAll(); continuation.finish()
        await closeTransport()
    }
    func shutdown() async throws {
        if !closed { closed = true; requests.removeAll(); continuation.finish(); input = nil }
        await closeTransport()
    }

    private func closeTransport() async {
        try? await wire.close()
        let file = runtimeFile; runtimeFile = nil
        try? await file?.remove()
    }

    private func parseHook(_ value: JSONValue) async {
        guard let id = AgentSetupSnapshot.name(value["hook_id"]),
              let rawName = value["hook_name"]?.stringValue, rawName.utf8.count <= 512,
              let event = value["hook_event"]?.stringValue, event.utf8.count <= 128,
              hookPhases.count < 2048 || hookPhases[id] != nil else { return }
        let phase: AgentHookEvent.Phase
        if value["subtype"]?.stringValue == "hook_started" {
            guard hookPhases[id] == nil else { return }; phase = .running
        } else {
            guard hookPhases[id] == nil || hookPhases[id] == .running else { return }
            let exit = value["exit_code"]?.int, outcome = value["outcome"]?.stringValue
            let output = value["stdout"]?.stringValue.flatMap(JSONValue.parse)
            let decision = value["decision"]?.stringValue ?? value["hookSpecificOutput"]?["permissionDecision"]?.stringValue
                ?? output?["decision"]?.stringValue ?? output?["hookSpecificOutput"]?["permissionDecision"]?.stringValue
            guard exit != nil || ["success", "error"].contains(outcome ?? "") || ["block", "deny"].contains(decision ?? "") else { return }
            phase = exit == 2 || ["block", "deny"].contains(decision ?? "") ? .blocked
                : ((exit ?? 0) != 0 || outcome == "error" ? .error : .success)
        }
        hookPhases[id] = phase
        let tool = rawName.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let status = availableSetup.metadata.statusMessage(event: event, tool: tool)
        var reason: String?
        if phase == .blocked || phase == .error {
            let output = value["stdout"]?.stringValue.flatMap(JSONValue.parse)
            let text = [value["stderr"]?.stringValue, value["reason"]?.stringValue,
                value["hookSpecificOutput"]?["permissionDecisionReason"]?.stringValue,
                output?["reason"]?.stringValue, output?["hookSpecificOutput"]?["permissionDecisionReason"]?.stringValue]
                .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ?? (phase == .blocked ? "Hook blocked." : "Hook failed.")
            let runtimeRedacted = await runtimeFile?.redacted(text) ?? text
            reason = AgentTranscriptContent.shortHookReason(await metadataReader.redact(runtimeRedacted))
        }
        let name = await metadataReader.redact(rawName, limit: 512)
        let safeEvent = await metadataReader.redact(event, limit: 128)
        let toolID = AgentSetupSnapshot.name(value["tool_use_id"])
        emit(.hook(.init(id: id, name: name, event: safeEvent, phase: phase, statusMessage: status, reason: reason,
                         toolUseID: toolID)), item: toolID)
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
                rememberAutonomousTool(.init(name: block["name"]?.stringValue ?? "", input: block["input"] ?? .null))
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
    private func injectedReason(_ value: JSONValue) -> AgentAutonomousReason? {
        let content = value["message"]?["content"] ?? .null
        let text = (content.stringValue ?? hookOutputStrings(content).joined(separator: "\n")).lowercased()
        if text.contains("<task-notification>") { return .backgroundTask }
        if text.contains("scheduled-wakeup") || text.contains("scheduled_wakeup") { return .wakeup }
        if text.contains("<system-reminder>") {
            if text.contains("monitor") { return .monitor }
            if text.contains("cron") || text.contains("scheduled") { return .scheduled }
            if text.contains("wakeup") || text.contains("wake-up") { return .wakeup }
        }
        return nil
    }
    private func rememberAutonomousTool(_ tool: AgentTool) {
        switch tool.name {
        case "ScheduleWakeup": lastAutonomousReason = .wakeup
        case "CronCreate": lastAutonomousReason = .scheduled
        case "Monitor": lastAutonomousReason = .monitor
        case "Bash" where tool.input["run_in_background"]?.boolValue == true: lastAutonomousReason = .backgroundTask
        default: break
        }
    }
    private func parseMessage(_ value: JSONValue) async {
        let message = value["message"] ?? .null
        let messageID = message["id"]?.stringValue ?? value["uuid"]?.stringValue
        let blocks = message["content"]?.arrayValue ?? []
        var texts: [String] = []
        if let text = message["content"]?.stringValue { texts.append(text) }
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text": if let text = block["text"]?.stringValue { texts.append(text) }
            case "thinking":
                if messageID == nil || !streamedThinking.contains(messageID!) {
                    emit(.thinkingDelta(block["thinking"]?.stringValue ?? ""), item: messageID)
                }
            case "tool_use":
                let tool = AgentTool(name: block["name"]?.stringValue ?? "", input: block["input"] ?? .null)
                rememberAutonomousTool(tool)
                emit(.toolStarted(tool), item: block["id"]?.stringValue)
            case "tool_result":
                var output = block["content"] ?? .null
                // Redact before bounding: clipping a long credential first
                // would leave a prefix which no longer matches the secret.
                let raw = hookOutputStrings(output).joined(separator: "\n")
                if raw.contains("hook error:") {
                    let runtimeRedacted = await runtimeFile?.redacted(raw) ?? raw
                    output = .string(await metadataReader.redact(runtimeRedacted))
                }
                emit(.toolFinished(output: output, isError: block["is_error"]?.boolValue ?? false), item: block["tool_use_id"]?.stringValue)
            default: emit(.unknown(name: block["type"]?.stringValue ?? "content", payload: block), item: messageID)
            }
        }
        if message["role"]?.stringValue == "user" {
            // Tool-result UUIDs identify tool output, not an echo of our input.
            // Emit their completions above without binding a user message ID.
            if !blocks.isEmpty, blocks.allSatisfy({ $0["type"]?.stringValue == "tool_result" }) { return }
            texts = [ClaudeCommandText.display(texts.joined(separator: "\n"))]
        }
        if let messageID, !texts.isEmpty {
            let native = value["uuid"]?.stringValue ?? messageID
            let role = message["role"]?.stringValue ?? "assistant"
            let text = messageID == streamingMessageID && !streamTexts.isEmpty
                ? streamTexts.keys.sorted().compactMap { streamTexts[$0] }.joined(separator: "\n") : texts.joined(separator: "\n")
            if role == "user", let queuedID = UUID(uuidString: native), queue.contains(queuedID) {
                let owner = AgentEventScope(runID: id, session: session, inputID: queuedID, itemID: messageID)
                continuation.yield(.init(scope: owner, kind: .delivery(.acknowledged)))
                continuation.yield(.init(scope: owner, kind: .message(id: native, role: role, text: text)))
            } else { emit(.message(id: native, role: role, text: text), item: messageID) }
        }
    }

    // Preserve string contents, rather than JSON-escaping credentials before
    // matching them. The wire already bounds the entire provider message.
    private func hookOutputStrings(_ value: JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .array(let values): values.flatMap(hookOutputStrings)
        case .object(let fields): fields.keys.sorted().flatMap { hookOutputStrings(fields[$0]!) }
        default: []
        }
    }
}

extension AgentMode {
    var claudePermission: String { self == .ask ? "default" : rawValue }
}

func claudeRateLimits(_ value: JSONValue) -> [AgentRateLimitWindow] {
    (value["unifiedWindows"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { key, window in
        AgentRateLimitWindow(id: key, utilization: window["utilization"]?.doubleValue.map { min(1, max(0, $0)) },
            duration: key == "five_hour" ? 5 * 3600 : key == "seven_day" ? 7 * 86400 : nil,
            resetsAt: window["resetsAt"]?.usageResetDate)
    }
}
