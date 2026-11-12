import Foundation
import CryptoKit

/// Fixed messages only: never expose a native file's contents in diagnostics.
public enum AgentNativeHistoryError: Error, Sendable, Equatable {
    case invalidCursor, staleCursor, malformedHistory, incompleteHistory, notFound, tooLarge, identityConflict
}

func nativeCanonicalPath(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
extension AgentSessionID {
    /// Codex item identity includes its turn. JSON framing avoids ambiguous
    /// separators, and Claude's persisted UUID remains unchanged.
    public func canonicalMessageID(_ itemID: String, turnID: String?) -> String {
        guard provider == .codex, let turnID else { return itemID }
        return JSONValue.array([.string(turnID), .string(itemID)]).jsonString
    }
}
func nativePath(_ path: String, belongsTo root: String) -> Bool {
    path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
}

/// A local projection cursor is bound to both its query and complete snapshot.
/// Changed files fail rather than claiming that a later offset is complete.
enum NativeHistoryPagination {
    private struct Cursor: Codable { let key: String; let digest: String; let offset: Int }
    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func page<T: Sendable>(_ items: [T], cursor: String?, key: String, snapshot: String,
                                  size: Int = 50) throws -> AgentPage<T> {
        let digest = fingerprint(snapshot)
        var offset = 0
        if let cursor {
            guard let data = Data(base64Encoded: cursor), let value = try? JSONDecoder().decode(Cursor.self, from: data),
                  value.key == key, value.offset > 0, value.offset < items.count else { throw AgentNativeHistoryError.invalidCursor }
            guard value.digest == digest else { throw AgentNativeHistoryError.staleCursor }
            offset = value.offset
        }
        let end = min(items.count, offset + size)
        let next = end < items.count ? try JSONEncoder().encode(Cursor(key: key, digest: digest, offset: end)).base64EncodedString() : nil
        return AgentPage(items: Array(items[offset..<end]), nextCursor: next)
    }
}

/// Local Claude Code projects JSONL, compatible with the 2.1.300 recording
/// family. Unknown records/blocks are ignored. No SDK, CLI invocation or Node.
public struct ClaudeNativeHistory: Sendable {
    public static let formatVersion = "Claude Code projects JSONL (2.1.300)"
    public let projectsDirectory: URL
    public let profile: String
    public init(projectsDirectory: URL, profile: String = "default") {
        self.projectsDirectory = projectsDirectory; self.profile = profile
    }
    private struct Session {
        let summary: AgentSessionSummary
        let records: [JSONValue]
        let snapshot: String
    }
    private func files() throws -> [URL] {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectsDirectory.path, isDirectory: &directory) else { return [] }
        guard directory.boolValue else { throw AgentNativeHistoryError.malformedHistory }
        // Only top-level session files, never subagents or arbitrary descendants.
        let projects = try FileManager.default.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var files: [URL] = []
        for project in projects {
            try Task.checkCancellation()
            let info = try project.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { continue }
            files += try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        }
        return files.sorted { $0.path < $1.path }
    }
    private func read(_ file: URL) throws -> Session {
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw AgentNativeHistoryError.malformedHistory }
        guard (info.fileSize ?? 0) <= 32 * 1024 * 1024 else { throw AgentNativeHistoryError.tooLarge }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 32 * 1024 * 1024 else { throw AgentNativeHistoryError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw AgentNativeHistoryError.malformedHistory }
        var records: [JSONValue] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            try Task.checkCancellation()
            guard let value = JSONValue.parse(String(line)), value.objectValue != nil else {
                throw index == lines.count - 1 && !text.hasSuffix("\n")
                    ? AgentNativeHistoryError.incompleteHistory : AgentNativeHistoryError.malformedHistory
            }
            records.append(value)
        }
        let id = file.deletingPathExtension().lastPathComponent
        let own = records.filter { $0["isSidechain"]?.boolValue != true }
        guard let cwd = own.compactMap({ $0["cwd"]?.stringValue }).first,
              cwd.hasPrefix("/"), !cwd.contains("\0") else { throw AgentNativeHistoryError.malformedHistory }
        guard own.allSatisfy({ $0["sessionId"]?.stringValue.map { $0 == id } ?? true }) else {
            throw AgentNativeHistoryError.identityConflict
        }
        let title = own.last(where: { $0["type"]?.stringValue == "custom-title" })?["customTitle"]?.stringValue
            ?? own.first(where: { $0["type"]?.stringValue == "user" && $0["isMeta"]?.boolValue != true })
                .flatMap { Self.messageText($0["message"]?["content"]) }
            ?? "Claude chat"
        let displayTitle = String(title.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        return Session(summary: .init(id: .init(provider: .claude, profile: profile, nativeID: id),
            title: displayTitle.isEmpty ? "Claude chat" : displayTitle, directory: URL(fileURLWithPath: cwd),
            sourceVersion: own.compactMap { $0["version"]?.stringValue }.last ?? Self.formatVersion), records: own, snapshot: NativeHistoryPagination.fingerprint(text))
    }
    private static func messageText(_ content: JSONValue?) -> String? {
        if let text = content?.stringValue { return text }
        let parts = content?.arrayValue?.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil } ?? []
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
    public func list(folder: URL?, cursor: String?, archived: Bool = false) throws -> AgentPage<AgentSessionSummary> {
        guard !archived else { throw AgentFailure.unsupported }
        let root = folder.map(nativeCanonicalPath)
        var sessions: [AgentSessionSummary] = [], snapshots: [String] = []
        for file in try files() {
            let session = try read(file)
            if root == nil || nativePath(nativeCanonicalPath(session.summary.directory), belongsTo: root!) {
                sessions.append(session.summary); snapshots.append(session.summary.id.nativeID + ":" + session.snapshot)
            }
        }
        var seen = Set<AgentSessionID>()
        guard sessions.allSatisfy({ seen.insert($0.id).inserted }) else { throw AgentNativeHistoryError.identityConflict }
        return try NativeHistoryPagination.page(sessions, cursor: cursor,
            key: "claude-list:\(profile):\(root ?? "*")", snapshot: snapshots.joined(separator: "\n"))
    }
    public func history(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> {
        guard session.provider == .claude, session.profile == profile, session.host == "local",
              UUID(uuidString: session.nativeID) != nil else { throw AgentFailure.invalidRequest }
        let matches = try files().filter { $0.deletingPathExtension().lastPathComponent == session.nativeID }
        guard matches.count == 1, let file = matches.first else {
            throw matches.isEmpty ? AgentNativeHistoryError.notFound : AgentNativeHistoryError.identityConflict
        }
        let value = try read(file)
        let runID = UUID()
        // JSONL retains abandoned branches. Follow the last conversational leaf
        // through parentUuid, including tool-only records, before projecting text.
        let conversation = value.records.filter { ["user", "assistant"].contains($0["type"]?.stringValue ?? "") }
        var records = conversation
        if conversation.contains(where: { $0["parentUuid"] != nil }) {
            var byID: [String: JSONValue] = [:]
            for record in value.records {
                if let id = record["uuid"]?.stringValue {
                    guard byID.updateValue(record, forKey: id) == nil else { throw AgentNativeHistoryError.identityConflict }
                }
            }
            records = []
            var next = conversation.last?["uuid"]?.stringValue, visited = Set<String>()
            while let id = next {
                guard visited.insert(id).inserted, let record = byID[id] else { throw AgentNativeHistoryError.incompleteHistory }
                records.append(record)
                next = record["parentUuid"]?.stringValue
            }
            records.reverse()
        }
        var events: [AgentEvent] = [], seen = Set<String>(), pending: [String] = [], completed = Set<String>()
        for record in records {
            guard let role = record["type"]?.stringValue, ["user", "assistant"].contains(role),
                  record["isMeta"]?.boolValue != true,
                  let text = Self.messageText(record["message"]?["content"]), !text.isEmpty else { continue }
            guard let id = record["uuid"]?.stringValue, !id.isEmpty, seen.insert(id).inserted else {
                throw AgentNativeHistoryError.malformedHistory
            }
            pending.append(id)
            if role == "assistant", ["end_turn", "stop_sequence", "max_tokens"].contains(record["message"]?["stop_reason"]?.stringValue ?? "") {
                completed.formUnion(pending); pending = []
            }
            events.append(.init(scope: .init(runID: runID, session: session, itemID: id), kind: .message(id: id, role: role, text: text)))
        }
        let page = try NativeHistoryPagination.page(events, cursor: cursor, key: "claude-read:\(profile):\(session.nativeID)", snapshot: value.snapshot)
        return .init(items: page.items, nextCursor: page.nextCursor, completedItemIDs: completed)
    }
}
