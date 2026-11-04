import Foundation

public struct AgentToolState: Sendable, Equatable {
    public var id: String
    public var tool: AgentTool?
    public var output: JSONValue?
    public var isFinished = false
    public var isError = false
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
    private var outputID: UUID?
    private var thinkingID: UUID?
    private var toolEntryIDs: [String: UUID] = [:]
    private var provider: AgentProvider?
    private var sessionID: UUID?

    public init(chatID: UUID, entries: [AgentTranscriptEntry] = []) {
        self.chatID = chatID; self.entries = entries
    }
    public mutating func begin(_ input: AgentInput, session: AgentChatSession, outputID: UUID,
                               context: ChatContextProjection? = nil) {
        inputID = input.id; self.outputID = outputID; provider = session.provider; sessionID = session.id
        streamingText = ""; thinking = ""; thinkingID = nil; toolEntryIDs = [:]
        tools = []; pendingCards = []; usage = nil; outcome = nil; isRunning = true
        if !entries.contains(where: { $0.id == input.id }) {
            if let context {
                entries.append(.init(chatID: chatID, provider: session.provider, kind: "handover",
                    text: context.text, sessionID: session.id, position: entries.count))
            }
            entries.append(.init(id: input.id, chatID: chatID, provider: session.provider,
                                 kind: "user", text: input.text, sessionID: session.id, position: entries.count))
        }
    }

    /// Caller supplies IDs, keeping the reducer deterministic and testable.
    public mutating func reduce(_ event: AgentEvent, newEntryID: UUID) {
        switch event.kind {
        case .rateLimits(let windows): rateLimits = windows
        case .usage(let value): usage = value
        case .sessionStarted: break
        default:
            guard isRunning, event.scope.inputID == inputID, inputID != nil else { return }
            switch event.kind {
            case .textDelta(let text):
                streamingText += text
                put(id: outputID ?? newEntryID, kind: "assistant", text: streamingText)
            case .thinkingDelta(let text):
                thinking += text
                thinkingID = thinkingID ?? newEntryID
                put(id: thinkingID!, kind: "thinking", text: thinking)
            case .message(let nativeID, let role, let text):
                if let index = entries.firstIndex(where: { $0.sessionID == sessionID && $0.nativeMessageID == nativeID }) {
                    // Keep the original user text; a provider echo may include
                    // the exact handover already displayed separately.
                    if role != "user" { entries[index].text = text }
                } else if role == "user", let index = entries.firstIndex(where: { $0.id == inputID }) {
                    entries[index].nativeMessageID = nativeID
                } else {
                    put(id: role == "assistant" ? (outputID ?? newEntryID) : newEntryID,
                        kind: role, text: text, nativeID: nativeID)
                }
                if role == "assistant" { streamingText = ""; outputID = newEntryID }
            case .toolStarted(let tool):
                let index = toolIndex(event.scope.itemID ?? "tool")
                tools[index].tool = tool
                putTool(index, newEntryID: newEntryID)
            case .toolOutput(let output):
                let index = toolIndex(event.scope.itemID ?? "tool")
                tools[index].output = output
                putTool(index, newEntryID: newEntryID)
            case .toolFinished(let output, let error):
                let index = toolIndex(event.scope.itemID ?? "tool")
                tools[index].output = output; tools[index].isFinished = true; tools[index].isError = error
                putTool(index, newEntryID: newEntryID)
            case .turnEnded(let value): end(value)
            default: break
            }
        }
    }
    public mutating func end(_ value: AgentTurnOutcome) {
        outcome = value; isRunning = false; pendingCards = []
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
                "output": tool.output ?? .null, "finished": .bool(tool.isFinished), "isError": .bool(tool.isError)
            ]).jsonString
        }
    }
    private mutating func put(id: UUID, kind: String, text: String, nativeID: String? = nil) {
        guard let provider else { return }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].text = text; entries[index].nativeMessageID = nativeID
        } else {
            entries.append(.init(id: id, chatID: chatID, provider: provider, kind: kind, text: text,
                                 sessionID: sessionID, nativeMessageID: nativeID, position: entries.count))
        }
    }
}
