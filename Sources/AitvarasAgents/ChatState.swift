import Foundation

public struct AgentToolState: Sendable, Equatable {
    public var id: String
    public var tool: AgentTool?
    public var output: JSONValue?
    public var partialInput = ""
    public var isFinished = false
    public var isError = false
    public var completionUnconfirmed = false
    public var turnCompletedNormally = false
    public var isDenied = false
    var commandStartedAt: Date?
    var commandDuration: TimeInterval?

    var isCommand: Bool { tool.map(AgentToolPolicy.isCommandExecution) ?? false }
}

/// Value-only reduction. Requests in the event stream are observations, never
/// approval cards: the owner replaces pendingCards from the coordinator.
public struct ChatState: Sendable, Equatable {
    public let chatID: UUID
    public var entries: [AgentTranscriptEntry]
    public private(set) var streamingText = ""
    public private(set) var thinking = ""
    public private(set) var tools: [AgentToolState] = []
    public var pendingCards: [AgentRequest] = []
    public internal(set) var messageQueue = AgentMessageQueue()
    public var mcpSetup: AgentMCPLaunchStatus?
    public private(set) var agentSetup: AgentSetupSnapshot?
    public private(set) var usage: AgentUsage?
    public private(set) var rateLimits: [AgentRateLimitWindow] = []
    public private(set) var outcome: AgentTurnOutcome?
    public private(set) var isRunning = false
    public private(set) var turnOrigin: AgentTurnOrigin = .user
    public private(set) var inputID: UUID?
    public private(set) var delivery: AgentDeliveryState?
    public private(set) var acknowledgedMode: AgentMode?
    public private(set) var activePermissions: AgentChatPermissions?
    private var outputID: UUID?
    private var automaticInputID: UUID?
    private var thinkingIDs: [String: UUID] = [:]
    private var textIDs: [String: UUID] = [:]
    private var toolEntryIDs: [String: UUID] = [:]
    private var hookEntryIDs: [String: UUID] = [:]
    private var hooks: [String: AgentHookEvent] = [:]
    private var hookOrder: [String] = []
    private var hookTools: [String: String] = [:]
    private var finishedToolOrder: [String] = []
    private var closedPreHookBatches: Set<String> = []
    /// Denials inferred only from a blocking hook; a real successful result may override them.
    private var hookInferredDenials: Set<String> = []
    private var provider: AgentProvider?
    private var sessionID: UUID?

    public init(chatID: UUID, entries: [AgentTranscriptEntry] = []) {
        self.chatID = chatID; self.entries = entries
    }
    mutating func noteDelivery(_ value: AgentDeliveryState) { delivery = value }
    mutating func beginPermissions(_ permissions: AgentChatPermissions?) {
        activePermissions = permissions
        if let permissions { acknowledgedMode = permissions.mode }
    }
    mutating func restore(turn: AgentJournalTurn) {
        inputID = turn.id; delivery = turn.delivery
        if let stop = entries.reversed().compactMap(\.stoppedTurn).first(where: { $0.inputID == turn.id && $0.attempt == turn.resendCount }) {
            end(stop.reason.outcome)
        }
        else {
            switch turn.state {
            case .completed: end(.completed)
            case .interrupted: end(.interrupted)
            case .failed: end(.failed(.unknown))
            case .running: break
            }
        }
    }
    public mutating func begin(_ input: AgentInput, session: AgentChatSession, outputID: UUID,
                               context: ChatContextProjection? = nil, automatic: Bool = false) {
        resetTurn(id: input.id, provider: session.provider, sessionID: session.id, outputID: outputID)
        automaticInputID = automatic ? input.id : nil
        turnOrigin = .user; acknowledgedMode = session.mode
        delivery = .prepared
        if !automatic, !entries.contains(where: { $0.id == input.id }) {
            if let context {
                entries.append(.init(chatID: chatID, provider: session.provider, kind: "handover",
                    text: context.text, sessionID: session.id, position: entries.count))
            }
            entries.append(.init(id: input.id, chatID: chatID, provider: session.provider,
                                 kind: "user", text: input.text, payloadJSON: input.composerPayload(),
                                 sessionID: session.id, position: entries.count))
        }
    }

    public mutating func beginAutonomous(id: UUID, reason: AgentAutonomousReason,
                                         provider: AgentProvider, sessionID: UUID) {
        resetTurn(id: id, provider: provider, sessionID: sessionID, outputID: nil)
        turnOrigin = .autonomous(reason)
        entries.append(.init(id: id, chatID: chatID, provider: provider, kind: "wakeup", text: reason.markerText,
            payloadJSON: JSONValue.object(["reason": .string(reason.rawValue)]).jsonString,
            sessionID: sessionID, position: entries.count))
    }
    private mutating func resetTurn(id: UUID, provider: AgentProvider, sessionID: UUID, outputID: UUID?) {
        automaticInputID = nil
        inputID = id; self.outputID = outputID; self.provider = provider; self.sessionID = sessionID
        streamingText = ""; thinking = ""; thinkingIDs = [:]; textIDs = [:]; toolEntryIDs = [:]
        tools = []; pendingCards = []; usage = nil; rateLimits = []; outcome = nil; isRunning = true
        hookEntryIDs = [:]; hooks = [:]; hookOrder = []; hookTools = [:]; finishedToolOrder = []; closedPreHookBatches = []; hookInferredDenials = []
    }
    public func isStreaming(entryID: UUID) -> Bool {
        isRunning && textIDs.values.contains(entryID)
    }

    var partialOutput: String {
        entries.filter { textIDs.values.contains($0.id) }.map(\.text).joined(separator: "\n")
    }

    public mutating func appendFollowup(_ input: AgentInput, session: AgentChatSession) {
        entries.append(.init(id: input.id, chatID: chatID, provider: session.provider,
            kind: "user", text: input.text, payloadJSON: input.composerPayload(
                followup: session.provider == .claude ? "queued" : "steering"), sessionID: session.id, position: entries.count))
    }
    public mutating func markFollowup(_ id: UUID, status: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              var payload = entries[index].payloadJSON.flatMap(JSONValue.parse)?.objectValue,
              payload["followup"] != nil else { return }
        payload["followup"] = .string(status)
        entries[index].payloadJSON = JSONValue.object(payload).jsonString
    }

    mutating func updatePendingCards(_ cards: [AgentRequest], observedAt: Date) {
        let pending = Set(cards.compactMap(\.scope.itemID))
        for id in pendingCards.compactMap(\.scope.itemID) where !pending.contains(id) {
            guard let index = tools.firstIndex(where: { $0.id == id && $0.isCommand && !$0.isFinished }),
                  let entryID = toolEntryIDs[id] else { continue }
            tools[index].commandStartedAt = observedAt
            putTool(index, newEntryID: entryID)
        }
        pendingCards = cards
    }

    /// Caller supplies IDs and observation times, keeping reduction deterministic.
    public mutating func reduce(_ event: AgentEvent, newEntryID: UUID, observedAt: Date? = nil) {
        switch event.kind {
        case .setupReported(let snapshot): agentSetup = snapshot
        case .hook(let hook):
            guard isRunning, event.scope.inputID == nil || event.scope.inputID == inputID else { return }
            putHook(hook, newEntryID: newEntryID)
        case .modeChanged(let mode):
            guard event.scope.inputID == nil || event.scope.inputID == inputID else { return }
            acknowledgedMode = mode
        case .rateLimits(let windows): rateLimits = windows
        case .usage(let value): usage = value
        case .sessionStarted: break
        default:
            guard isRunning, event.scope.inputID == inputID, inputID != nil else { return }
            switch event.kind {
            case .delivery(let value): delivery = value
            case .textDelta(let text):
                closeEarlierTools()
                let key = event.scope.itemID ?? "text"
                let id = textIDs[key] ?? outputID ?? newEntryID
                if textIDs[key] == nil { textIDs[key] = id; outputID = nil }
                let previous = entries.first(where: { $0.id == id })?.text ?? ""
                streamingText = previous + text
                let nativeID: String?
                if let session = event.scope.session, session.provider == .codex,
                   let item = event.scope.itemID, let turn = event.scope.turnID {
                    nativeID = session.canonicalMessageID(item, turnID: turn)
                } else { nativeID = nil }
                put(id: id, kind: "assistant", text: streamingText, nativeID: nativeID)
            case .thinkingDelta(let text):
                putThinking(text, item: event.scope.itemID, complete: false, newEntryID: newEntryID)
            case .thinkingCompleted(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                putThinking(text, item: event.scope.itemID, complete: true, newEntryID: newEntryID)
            case .message(let nativeID, let role, let text):
                if role == "user", automaticInputID == inputID, text == AgentAutoContinue.prompt { break }
                if role == "assistant" { closeEarlierTools() }
                if let index = entries.firstIndex(where: { $0.sessionID == sessionID && $0.nativeMessageID == nativeID }) {
                    if role != "user" { entries[index].text = text }
                } else if role == "user", let index = entries.firstIndex(where: { $0.id == inputID }) {
                    guard entries[index].nativeMessageID == nil || entries[index].nativeMessageID == nativeID else { return }
                    entries[index].nativeMessageID = nativeID
                } else {
                    let key = event.scope.itemID ?? "text"
                    let id = role == "assistant" ? (textIDs[key] ?? textIDs.removeValue(forKey: "text") ?? outputID ?? newEntryID) : newEntryID
                    put(id: id, kind: role, text: text, nativeID: nativeID)
                    if role == "assistant" { textIDs[key] = id; outputID = nil }
                }
                if event.scope.turnID != nil || event.scope.isCommentary,
                   let index = entries.firstIndex(where: { $0.sessionID == sessionID && $0.nativeMessageID == nativeID }) {
                    var payload = entries[index].payloadJSON.flatMap(JSONValue.parse)?.objectValue ?? [:]
                    if let turnID = event.scope.turnID { payload["nativeTurnID"] = .string(turnID) }
                    if event.scope.isCommentary { payload["commentary"] = .bool(true) }
                    entries[index].payloadJSON = JSONValue.object(payload).jsonString
                }
                if role == "assistant" { streamingText = "" }
            case .toolStarted(let tool):
                let itemID = event.scope.itemID ?? "tool"
                // Interleaved providers can announce the next tool while a
                // previous tool's hook response is still in flight.
                if !toolEntryIDs.keys.contains(itemID) {
                    for id in hookOrder where hooks[id]?.event == "PreToolUse" {
                        if let owner = hookTools[id] { closedPreHookBatches.insert(owner) }
                    }
                }
                closeEarlierTools(before: itemID)
                let index = toolIndex(itemID)
                tools[index].tool = AgentTool(name: tool.name, input: AgentTranscriptContent.bounded(tool.input))
                if tools[index].isCommand, tools[index].commandStartedAt == nil {
                    tools[index].commandStartedAt = observedAt
                }
                putTool(index, newEntryID: newEntryID)
            case .toolInputDelta(let delta):
                let index = toolIndex(event.scope.itemID ?? "tool")
                guard !tools[index].isFinished || tools[index].completionUnconfirmed else { return }
                tools[index].partialInput = AgentTranscriptContent.append(delta, to: tools[index].partialInput)
                putTool(index, newEntryID: newEntryID)
            case .toolOutput(let output):
                let index = toolIndex(event.scope.itemID ?? "tool")
                guard !tools[index].isFinished || tools[index].completionUnconfirmed else { return }
                if let text = output.stringValue {
                    let previous = tools[index].output?.stringValue ?? ""
                    tools[index].output = .string(tools[index].isCommand
                        ? AgentCommandTranscript.boundedOutputTail(previous + text)
                        : AgentTranscriptContent.append(text, to: previous))
                } else { tools[index].output = AgentTranscriptContent.bounded(output) }
                putTool(index, newEntryID: newEntryID)
            case .toolFinished(let output, let error):
                let index = toolIndex(event.scope.itemID ?? "tool")
                let finishedID = tools[index].id
                finishedToolOrder.removeAll { $0 == finishedID }
                if output != .null {
                    tools[index].output = tools[index].isCommand
                        ? AgentCommandTranscript.completedOutput(output, streamed: tools[index].output)
                        : AgentTranscriptContent.bounded(output)
                }
                if let observedAt, let startedAt = tools[index].commandStartedAt,
                   tools[index].commandDuration == nil {
                    tools[index].commandDuration = max(0, observedAt.timeIntervalSince(startedAt))
                }
                tools[index].isFinished = true
                tools[index].completionUnconfirmed = false
                tools[index].turnCompletedNormally = false
                // Provider and approval denials are authoritative; only a hook-inferred
                // denial yields to a real successful result.
                let toolID = tools[index].id
                let keepsDenial = tools[index].isDenied && (error || !hookInferredDenials.contains(toolID))
                tools[index].isDenied = output["status"]?.stringValue == "declined" || keepsDenial
                tools[index].isError = error || tools[index].isDenied
                putTool(index, newEntryID: newEntryID)
            case .turnEnded(let value): end(value)
            default: break
            }
        }
    }
    /// A Claude result consumes every input already written to that native turn.
    /// Keep earlier observations, but move the answer after the latest user input.
    mutating func completeCoalescedTurn(latest: AgentInput, outcome: AgentTurnOutcome) -> String {
        let answerIDs = Set(textIDs.values)
        var answers = entries.filter { $0.kind == "assistant" && answerIDs.contains($0.id) }
        entries.removeAll { $0.kind == "assistant" && answerIDs.contains($0.id) }
        for index in answers.indices {
            var payload = answers[index].payloadJSON.flatMap(JSONValue.parse)?.objectValue ?? [:]
            payload["inputID"] = .string(latest.id.uuidString)
            answers[index].payloadJSON = JSONValue.object(payload).jsonString
        }
        entries += answers
        for index in entries.indices { entries[index].position = index }
        inputID = latest.id
        end(outcome)
        return answers.map(\.text).joined(separator: "\n")
    }

    mutating func awaitingQueuedInput() { isRunning = true; outcome = nil }
    public mutating func end(_ value: AgentTurnOutcome) {
        for hook in Array(hooks.values) where hook.phase == .running {
            putHook(.init(id: hook.id, name: hook.name, event: hook.event, phase: .interrupted,
                          statusMessage: hook.statusMessage, reason: "Hook ended without a response.", toolUseID: hook.toolUseID), newEntryID: hookEntryIDs[hook.id] ?? inputID ?? chatID)
        }
        // A summary-only turn/completed need not repeat its tool items. Stop,
        // disconnect and missing item completions must still close their rows,
        // without inventing a successful command result.
        for index in tools.indices where !tools[index].isFinished || tools[index].completionUnconfirmed {
            tools[index].isFinished = true
            tools[index].completionUnconfirmed = true
            tools[index].turnCompletedNormally = value == .completed
            if let id = toolEntryIDs[tools[index].id] { putTool(index, newEntryID: id) }
        }
        outcome = value; isRunning = false; pendingCards = []
    }
    private mutating func closeEarlierTools(before itemID: String? = nil) {
        // Later CLI work proves earlier tools stopped running, but does not
        // prove success. Keep pending approvals and accept a real result later.
        let end = itemID.flatMap { id in tools.firstIndex { $0.id == id } } ?? tools.endIndex
        for index in tools.indices.prefix(end) where !tools[index].isFinished {
            guard !pendingCards.contains(where: { $0.scope.itemID == tools[index].id }) else { continue }
            tools[index].isFinished = true
            tools[index].completionUnconfirmed = true
            tools[index].turnCompletedNormally = true
            if let id = toolEntryIDs[tools[index].id] { putTool(index, newEntryID: id) }
        }
    }
    private mutating func putThinking(_ text: String, item: String?, complete: Bool, newEntryID: UUID) {
        let key = item ?? "thinking"
        let id = thinkingIDs[key] ?? newEntryID
        thinkingIDs[key] = id
        let previous = entries.first(where: { $0.id == id })?.text ?? ""
        let value = complete ? AgentTranscriptContent.bounded(text) : AgentTranscriptContent.append(text, to: previous)
        put(id: id, kind: "thinking", text: value)
        thinking = AgentTranscriptContent.bounded(entries.filter { thinkingIDs.values.contains($0.id) }.map(\.text).joined(separator: "\n"))
    }
    private mutating func toolIndex(_ id: String) -> Int {
        if let index = tools.firstIndex(where: { $0.id == id }) { return index }
        tools.append(AgentToolState(id: id)); return tools.count - 1
    }
    private mutating func putTool(_ index: Int, newEntryID: UUID) {
        let tool = tools[index]
        if tool.isFinished, !finishedToolOrder.contains(tool.id) { finishedToolOrder.append(tool.id) }
        let id = toolEntryIDs[tool.id] ?? newEntryID
        toolEntryIDs[tool.id] = id
        put(id: id, kind: "tool", text: tool.tool?.name ?? "")
        if let entry = entries.firstIndex(where: { $0.id == id }) {
            entries[entry].payloadJSON = JSONValue.object([
                "itemID": .string(tool.id), "input": tool.tool?.input ?? .null,
                "partialInput": .string(tool.partialInput), "output": tool.output ?? .null, "finished": .bool(tool.isFinished), "isError": .bool(tool.isError),
                "completionUnconfirmed": .bool(tool.completionUnconfirmed),
                "turnCompletedNormally": .bool(tool.turnCompletedNormally), "isDenied": .bool(tool.isDenied),
                "commandStartedAt": tool.commandStartedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                "commandDuration": tool.commandDuration.map(JSONValue.number) ?? .null
            ]).jsonString
            let related = hookOrder.compactMap { hookTools[$0] == tool.id ? hooks[$0] : nil }
            if !related.isEmpty, var payload = entries[entry].payloadJSON.flatMap(JSONValue.parse)?.objectValue {
                payload["hooks"] = .array(related.map { hook in
                    .object(["id": .string(hook.id), "name": .string(hook.name), "event": .string(hook.event),
                        "status": .string(Self.hookStatus(hook.phase)),
                        "reason": hook.reason.map { .string(AgentTranscriptContent.shortHookReason($0)) } ?? .null])
                }); entries[entry].payloadJSON = JSONValue.object(payload).jsonString
            }
        }
    }
    private static func hookStatus(_ phase: AgentHookEvent.Phase) -> String {
        switch phase { case .running: "running"; case .success: "passed"; case .blocked: "blocked"; case .error, .interrupted: "failed" }
    }
    private static func hookPayload(_ hook: AgentHookEvent) -> JSONValue {
        .object(["hookID": .string(hook.id), "name": .string(hook.name), "event": .string(hook.event),
            "phase": .string(hook.phase.rawValue), "statusMessage": hook.statusMessage.map(JSONValue.string) ?? .null,
            "reason": hook.reason.map(JSONValue.string) ?? .null])
    }
    private mutating func putHook(_ hook: AgentHookEvent, newEntryID: UUID) {
        if let prior = hooks[hook.id], prior.phase != .running { return }
        guard hooks.count < 2048 || hooks[hook.id] != nil else { return }
        if hooks[hook.id] == nil {
            hookOrder.append(hook.id)
            if let explicit = hook.toolUseID { hookTools[hook.id] = explicit }
            else if hook.phase == .running, ["PreToolUse", "PostToolUse"].contains(hook.event),
                    hook.name.hasPrefix(hook.event + ":") {
                let name = String(hook.name.dropFirst(hook.event.count + 1))
                let finished = hook.event == "PostToolUse" ? finishedToolOrder.reversed().compactMap { id in
                    tools.first { $0.id == id && $0.tool?.name == name && $0.isFinished }
                }.first : nil
                let match: AgentToolState?
                if hook.event == "PreToolUse" {
                    let eligible = tools.first { tool in
                        tool.tool?.name == name && (!tool.isFinished || tool.completionUnconfirmed)
                            && !closedPreHookBatches.contains(tool.id)
                            && !hookOrder.contains { id in
                                hookTools[id] == tool.id && hooks[id]?.event == "PreToolUse" && hooks[id]?.phase != .running
                            }
                    }
                    // Older/interleaved streams can report configured hooks
                    // sequentially. Keep that live batch when no next tool waits.
                    match = eligible ?? tools.last { $0.tool?.name == name && !$0.isFinished && !closedPreHookBatches.contains($0.id) }
                } else { match = tools.last { $0.tool?.name == name && !$0.isFinished } ?? finished }
                hookTools[hook.id] = match?.id
            }
        }
        hooks[hook.id] = hook
        // Bind once at first observation. A later same-name tool cannot steal
        // this hook's response; unmatched starts remain standalone too.
        if let tool = hookTools[hook.id] {
            let index = toolIndex(tool)
            let realSuccess = tools[index].isFinished && !tools[index].completionUnconfirmed && !tools[index].isError
            if hook.phase == .blocked && !realSuccess {
                if !tools[index].isDenied { hookInferredDenials.insert(tools[index].id) }
                tools[index].isDenied = true; tools[index].isFinished = true; tools[index].isError = true
            }
            putTool(index, newEntryID: newEntryID); return
        }
        let id = hookEntryIDs[hook.id] ?? newEntryID
        hookEntryIDs[hook.id] = id
        put(id: id, kind: "hook", text: hook.statusMessage ?? hook.name)
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].payloadJSON = Self.hookPayload(hook).jsonString }
    }
    private mutating func put(id: UUID, kind: String, text: String, nativeID: String? = nil) {
        guard let provider else { return }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].text = text
            if let nativeID { entries[index].nativeMessageID = nativeID }
        } else {
            entries.append(.init(id: id, chatID: chatID, provider: provider, kind: kind, text: text,
                                 sessionID: sessionID, nativeMessageID: nativeID, position: entries.count))
        }
        if let automaticInputID, let index = entries.firstIndex(where: { $0.id == id }) {
            var payload = entries[index].payloadJSON.flatMap(JSONValue.parse)?.objectValue ?? [:]
            payload["journalInputID"] = .string(automaticInputID.uuidString)
            entries[index].payloadJSON = JSONValue.object(payload).jsonString
        }
    }
}
