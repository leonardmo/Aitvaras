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
    public private(set) var usage: AgentUsage?
    public private(set) var rateLimits: [AgentRateLimitWindow] = []
    public private(set) var outcome: AgentTurnOutcome?
    public private(set) var isRunning = false
    public private(set) var inputID: UUID?
    public private(set) var acknowledgedMode: AgentMode?
    private var outputID: UUID?
    private var thinkingIDs: [String: UUID] = [:]
    private var textIDs: [String: UUID] = [:]
    private var toolEntryIDs: [String: UUID] = [:]
    private var provider: AgentProvider?
    private var sessionID: UUID?

    public init(chatID: UUID, entries: [AgentTranscriptEntry] = []) {
        self.chatID = chatID; self.entries = entries
    }
    public mutating func begin(_ input: AgentInput, session: AgentChatSession, outputID: UUID,
                               context: ChatContextProjection? = nil) {
        inputID = input.id; self.outputID = outputID; provider = session.provider; sessionID = session.id
        acknowledgedMode = session.mode
        streamingText = ""; thinking = ""; thinkingIDs = [:]; textIDs = [:]; toolEntryIDs = [:]
        tools = []; pendingCards = []; usage = nil; outcome = nil; isRunning = true
        if !entries.contains(where: { $0.id == input.id }) {
            if let context {
                entries.append(.init(chatID: chatID, provider: session.provider, kind: "handover",
                    text: context.text, sessionID: session.id, position: entries.count))
            }
            entries.append(.init(id: input.id, chatID: chatID, provider: session.provider,
                                 kind: "user", text: input.text, payloadJSON: input.composerPayload(),
                                 sessionID: session.id, position: entries.count))
        }
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

    /// Caller supplies IDs, keeping the reducer deterministic and testable.
    public mutating func reduce(_ event: AgentEvent, newEntryID: UUID) {
        switch event.kind {
        case .modeChanged(let mode):
            guard event.scope.inputID == nil || event.scope.inputID == inputID else { return }
            acknowledgedMode = mode
        case .rateLimits(let windows): rateLimits = windows
        case .usage(let value): usage = value
        case .sessionStarted: break
        default:
            guard isRunning, event.scope.inputID == inputID, inputID != nil else { return }
            switch event.kind {
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
                putThinking(text, item: event.scope.itemID, complete: true, newEntryID: newEntryID)
            case .message(let nativeID, let role, let text):
                if role == "assistant" { closeEarlierTools() }
                if let index = entries.firstIndex(where: { $0.sessionID == sessionID && $0.nativeMessageID == nativeID }) {
                    if role != "user" { entries[index].text = text }
                } else if role == "user", let index = entries.firstIndex(where: { $0.id == inputID }) {
                    entries[index].nativeMessageID = nativeID
                } else {
                    let key = event.scope.itemID ?? "text"
                    let id = role == "assistant" ? (textIDs[key] ?? textIDs.removeValue(forKey: "text") ?? outputID ?? newEntryID) : newEntryID
                    put(id: id, kind: role, text: text, nativeID: nativeID)
                    if role == "assistant" { textIDs[key] = id; outputID = nil }
                }
                if let turnID = event.scope.turnID,
                   let index = entries.firstIndex(where: { $0.sessionID == sessionID && $0.nativeMessageID == nativeID }) {
                    var payload = entries[index].payloadJSON.flatMap(JSONValue.parse)?.objectValue ?? [:]
                    payload["nativeTurnID"] = .string(turnID)
                    entries[index].payloadJSON = JSONValue.object(payload).jsonString
                }
                if role == "assistant" { streamingText = "" }
            case .toolStarted(let tool):
                let itemID = event.scope.itemID ?? "tool"
                closeEarlierTools(before: itemID)
                let index = toolIndex(itemID)
                tools[index].tool = AgentTool(name: tool.name, input: AgentTranscriptContent.bounded(tool.input))
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
                    tools[index].output = .string(AgentTranscriptContent.append(text, to: tools[index].output?.stringValue ?? ""))
                } else { tools[index].output = AgentTranscriptContent.bounded(output) }
                putTool(index, newEntryID: newEntryID)
            case .toolFinished(let output, let error):
                let index = toolIndex(event.scope.itemID ?? "tool")
                if output != .null { tools[index].output = AgentTranscriptContent.bounded(output) }
                tools[index].isFinished = true
                tools[index].completionUnconfirmed = false
                tools[index].turnCompletedNormally = false
                tools[index].isDenied = tools[index].isDenied || output["status"]?.stringValue == "declined"
                tools[index].isError = error || tools[index].isDenied
                putTool(index, newEntryID: newEntryID)
            case .turnEnded(let value): end(value)
            default: break
            }
        }
    }
    mutating func awaitingQueuedInput() { isRunning = true; outcome = nil }
    public mutating func end(_ value: AgentTurnOutcome) {
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
        let id = toolEntryIDs[tool.id] ?? newEntryID
        toolEntryIDs[tool.id] = id
        put(id: id, kind: "tool", text: tool.tool?.name ?? "")
        if let entry = entries.firstIndex(where: { $0.id == id }) {
            entries[entry].payloadJSON = JSONValue.object([
                "itemID": .string(tool.id), "input": tool.tool?.input ?? .null,
                "partialInput": .string(tool.partialInput), "output": tool.output ?? .null, "finished": .bool(tool.isFinished), "isError": .bool(tool.isError),
                "completionUnconfirmed": .bool(tool.completionUnconfirmed),
                "turnCompletedNormally": .bool(tool.turnCompletedNormally), "isDenied": .bool(tool.isDenied)
            ]).jsonString
        }
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
    }
}
