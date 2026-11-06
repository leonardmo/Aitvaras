import Foundation

extension CodexBackend {
    public func listSessions(folder: URL, cursor: String?) async throws -> AgentPage<AgentSessionSummary> {
        try await nativeSessions(folder: folder, cursor: cursor, archived: false)
    }
    public func nativeSessions(folder: URL?, cursor: String?, archived: Bool) async throws -> AgentPage<AgentSessionSummary> {
        try requireNativeHistory()
        var parameters: [String: JSONValue] = ["limit": .number(50), "archived": .bool(archived),
            "sortKey": .string("updated_at"), "modelProviders": .array([.string("openai")])]
        if let cursor { parameters["cursor"] = .string(cursor) }
        // List broadly: the server's exact string cwd filter misses symlink
        // aliases and nested project folders. Filter canonical paths locally.
        let result = try await rpc("thread/list", .object(parameters))
        guard let data = result["data"]?.arrayValue else { throw AgentNativeHistoryError.malformedHistory }
        let next = try nativeNextCursor(result["nextCursor"], previous: cursor)
        var seen = Set<AgentSessionID>()
        let root = folder.map(nativeCanonicalPath)
        let items = try data.map { try nativeSummary($0, archived: archived) }.filter {
            root == nil || nativePath(nativeCanonicalPath($0.directory), belongsTo: root!)
        }
        guard items.allSatisfy({ seen.insert($0.id).inserted }) else { throw AgentNativeHistoryError.identityConflict }
        return .init(items: items, nextCursor: next)
    }
    public func readHistory(session: AgentSessionID, cursor: String?) async throws -> AgentPage<AgentEvent> {
        try validateNativeSession(session)
        let result = try await rpc("thread/read", .object(["threadId": .string(session.nativeID), "includeTurns": .bool(true)]))
        guard let thread = result["thread"], thread["id"]?.stringValue == session.nativeID,
              let turns = thread["turns"]?.arrayValue else { throw AgentNativeHistoryError.malformedHistory }
        // This reader supports the recorded full-history surface only. Never
        // label a paginated/summary response complete; M5.3 handles reconciliation.
        guard thread["historyMode"]?.stringValue.map({ $0 == "legacy" }) ?? true,
              turns.allSatisfy({ $0["itemsView"]?.stringValue.map { $0 == "full" } ?? true }) else {
            throw AgentFailure.unsupported
        }
        let runID = UUID()
        var events: [AgentEvent] = [], seen = Set<String>(), completed = Set<String>(), turnIDs = Set<String>()
        for turn in turns {
            guard let turnID = turn["id"]?.stringValue, !turnID.isEmpty, turnIDs.insert(turnID).inserted,
                  let items = turn["items"]?.arrayValue else {
                throw AgentNativeHistoryError.malformedHistory
            }
            for item in items {
                guard let type = item["type"]?.stringValue else { throw AgentNativeHistoryError.malformedHistory }
                let role: String, text: String
                switch type {
                case "userMessage":
                    guard let content = item["content"]?.arrayValue else { throw AgentNativeHistoryError.malformedHistory }
                    role = "user"; text = content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
                case "agentMessage":
                    guard let value = item["text"]?.stringValue else { throw AgentNativeHistoryError.malformedHistory }
                    role = "assistant"; text = value
                default: continue // tool/unknown records are not invented text
                }
                guard let id = item["id"]?.stringValue, !id.isEmpty,
                      seen.insert(session.canonicalMessageID(id, turnID: turnID)).inserted else {
                    throw AgentNativeHistoryError.malformedHistory
                }
                if !text.isEmpty {
                    if turn["status"]?.stringValue == "completed" { completed.insert(session.canonicalMessageID(id, turnID: turnID)) }
                    events.append(.init(scope: .init(runID: runID, session: session, turnID: turnID, itemID: id),
                        kind: .message(id: id, role: role, text: text)))
                }
            }
        }
        let page = try NativeHistoryPagination.page(events, cursor: cursor,
            key: "codex-read:\(session.host):\(session.profile):\(session.nativeID)", snapshot: thread.jsonString)
        return .init(items: page.items, nextCursor: page.nextCursor, completedItemIDs: completed)
    }
    private func nativeSummary(_ value: JSONValue, archived: Bool) throws -> AgentSessionSummary {
        guard let id = value["id"]?.stringValue, !id.isEmpty,
              let cwd = value["cwd"]?.stringValue, cwd.hasPrefix("/"), !cwd.contains("\0"),
              value["modelProvider"]?.stringValue == "openai" else { throw AgentNativeHistoryError.malformedHistory }
        let title = String((value["name"]?.stringValue ?? value["preview"]?.stringValue ?? "").prefix(200))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(id: nativeSessionID(id), title: title.isEmpty ? "Codex chat" : title,
                     directory: URL(fileURLWithPath: cwd), sourceVersion: value["cliVersion"]?.stringValue, archived: archived)
    }
}

private func nativeNextCursor(_ value: JSONValue?, previous: String?) throws -> String? {
    guard let value, value != .null else { return nil }
    guard let next = value.stringValue, !next.isEmpty, next != previous else { throw AgentNativeHistoryError.invalidCursor }
    return next
}
