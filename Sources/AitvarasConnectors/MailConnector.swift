import AppKit
import Foundation
import AitvarasCore
import AitvarasStore

/// Escapes a string for embedding inside a double-quoted AppleScript string
/// literal. AppleScript only treats `\` and `"` specially; everything going
/// into a script MUST pass through this (hard rule — scripts are built from
/// model-provided arguments).
func appleScriptEscaped(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Error from NSAppleScript execution, keeping the OSA error number so
/// callers can distinguish "automation denied" (-1743) from real failures.
struct AppleScriptError: Error, LocalizedError, Sendable {
    let code: Int
    let message: String
    var errorDescription: String? { "AppleScript error \(code): \(message)" }
}

/// Apple Mail via AppleScript (D5). Reads across all accounts' inboxes
/// without changing read status (property access never marks messages read).
/// New-mail detection polls every minute for messages received in the last
/// 15 minutes, deduplicated through `Stores.markSeen` — the belt to the
/// Mail-rule suspenders discussed in D5.
public actor MailConnector: Connector {
    public nonisolated let id = "mail"
    public nonisolated let displayName = "Mail"

    private let stores: Stores
    /// NSAppleScript is not thread-safe — every script runs on this queue.
    private let scriptQueue = DispatchQueue(label: "app.aitvaras.mail.applescript")

    private let eventStream: AsyncStream<ConnectorEvent>
    private let eventContinuation: AsyncStream<ConnectorEvent>.Continuation
    private var pollTask: Task<Void, Never>?

    public init(stores: Stores) {
        self.stores = stores
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: ConnectorEvent.self)
    }

    deinit {
        pollTask?.cancel()
        eventContinuation.finish()
    }

    public nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "recent_messages",
            description: "The most recent messages across all Mail inboxes (does not mark anything read). Returns one compact JSON object per line with id, date, sender, subject and a content preview.",
            parametersJSON: """
            {"type":"object","properties":{"count":{"type":"integer","description":"How many messages, max 20 (default 10)"}},"required":[]}
            """,
            risk: .read
        ),
        ToolDefinition(
            name: "get_message",
            description: "Full content of one message by its message id (from recent_messages). Does not mark it read.",
            parametersJSON: """
            {"type":"object","properties":{"messageID":{"type":"string"}},"required":["messageID"]}
            """,
            risk: .read
        ),
        ToolDefinition(
            name: "search_messages",
            description: "Search all Mail inboxes for messages whose subject or sender contains the query, newest first (does not mark anything read; can be slow on huge mailboxes). Returns one compact JSON object per line with id, date, sender, subject and a content preview.",
            parametersJSON: """
            {"type":"object","properties":{"query":{"type":"string","description":"Text to find in the subject or sender"},"count":{"type":"integer","description":"How many messages, max 20 (default 10)"}},"required":["query"]}
            """,
            risk: .read
        )
    ]

    public func health() async -> ConnectorHealth {
        let mailRunning = await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
        }
        guard mailRunning else {
            return .needsAuthentication(message: "Mail.app is not running. Launch Mail so Aitvaras can watch your inboxes.")
        }
        do {
            _ = try await runAppleScript("tell application \"Mail\" to return name")
            return .ready
        } catch let error as AppleScriptError where error.code == -1743 {
            return .needsAuthentication(message: "Automation access to Mail was denied. Allow Aitvaras to control Mail in System Settings → Privacy & Security → Automation.")
        } catch {
            return .error(message: "Mail is not reachable: \(error.localizedDescription)")
        }
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        let args = try ToolArgs(json: argumentsJSON)
        switch toolName {
        case "recent_messages":
            let count = min(max(args.int("count") ?? 10, 1), 20)
            let messages = try await fetchMessages(script: Self.recentMessagesScript(count: count, contentLimit: 1500))
            guard !messages.isEmpty else { return "No messages found in the inboxes." }
            return messages.map(\.jsonLine).joined(separator: "\n")
        case "get_message":
            let messageID = try args.requiredString("messageID")
            let messages = try await fetchMessages(script: Self.getMessageScript(messageID: messageID, contentLimit: 8000))
            guard let message = messages.first else {
                throw ConnectorError("No inbox message with message id '\(messageID)'.")
            }
            return message.jsonLine
        case "search_messages":
            let query = try args.requiredString("query")
            let count = min(max(args.int("count") ?? 10, 1), 20)
            let messages = try await fetchMessages(script: Self.searchMessagesScript(query: query, count: count, contentLimit: 500))
            guard !messages.isEmpty else { return "No inbox messages match '\(query)' in subject or sender." }
            return messages.map(\.jsonLine).joined(separator: "\n")
        default:
            throw ConnectorError("Mail connector has no tool named '\(toolName)'.")
        }
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        eventStream
    }

    /// Begin watching for new mail. Called by the app once at startup —
    /// the connector never polls on its own.
    public func startPolling(interval: TimeInterval = 60) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    private func pollOnce() async {
        guard let messages = try? await fetchMessages(
            script: Self.messagesSinceScript(secondsAgo: 15 * 60, contentLimit: 2000)) else { return }

        for message in messages {
            // markSeen returns true only the first time — provenance-stable dedup.
            guard (try? stores.markSeen(connectorID: id, itemID: message.messageID)) == true else { continue }
            eventContinuation.yield(ConnectorEvent(
                connectorID: id,
                sourceID: "mail:\(message.messageID)",
                title: "New mail from \(message.sender): \(message.subject)",
                body: String(message.content.prefix(2000)),
                occurredAt: message.date ?? .now))
        }
    }

    // MARK: - AppleScript execution

    private func runAppleScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            scriptQueue.async {
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(throwing: AppleScriptError(code: 0, message: "Could not compile AppleScript."))
                    return
                }
                var errorInfo: NSDictionary?
                let result = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                    let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
                    cont.resume(throwing: AppleScriptError(code: code, message: message))
                } else {
                    cont.resume(returning: result.stringValue ?? "")
                }
            }
        }
    }

    // MARK: - Message parsing

    struct Message: Sendable {
        var messageID: String
        var date: Date?
        var dateRaw: String
        var sender: String
        var subject: String
        var content: String

        var jsonLine: String {
            JSONText.object([
                ("id", .string(messageID)),
                ("date", .string(dateRaw)),
                ("sender", .string(sender)),
                ("subject", .string(subject)),
                ("content", .string(content))
            ])
        }
    }

    /// Scripts emit fields separated by ASCII 31 (unit separator) and
    /// records by ASCII 30 (record separator) — characters that cannot
    /// appear in mail headers and are trivially split here.
    static func parseMessages(_ raw: String) -> [Message] {
        raw.split(separator: "\u{1E}", omittingEmptySubsequences: true).compactMap { record in
            let fields = record.components(separatedBy: "\u{1F}")
            guard fields.count >= 5 else { return nil }
            let dateRaw = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            return Message(
                messageID: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
                date: ISO.parseDate(dateRaw),
                dateRaw: dateRaw,
                sender: fields[1],
                subject: fields[2],
                content: fields[4...].joined(separator: "\u{1F}"))
        }
    }

    private func fetchMessages(script: String) async throws -> [Message] {
        let raw = try await runAppleScript(script)
        return Self.parseMessages(raw)
    }

    // MARK: - Script builders

    /// Shared prologue: separators + a handler serializing one message.
    /// `content` access on Mail messages reads the body without changing
    /// read status (only opening in the UI marks messages read).
    private static func scriptPrologue(contentLimit: Int) -> String {
        """
        set fs to character id 31
        set rs to character id 30
        on serializeMessage(m, fs, rs, contentLimit)
            tell application "Mail"
                set mid to message id of m
                set msender to sender of m
                set msubject to subject of m
                set misodate to (date received of m) as «class isot» as string
                set mcontent to ""
                try
                    set mcontent to content of m
                end try
            end tell
            if (length of mcontent) > contentLimit then set mcontent to text 1 thru contentLimit of mcontent
            return mid & fs & msender & fs & msubject & fs & misodate & fs & mcontent & rs
        end serializeMessage
        """
    }

    /// N most recent messages of the unified inbox (all accounts).
    static func recentMessagesScript(count: Int, contentLimit: Int) -> String {
        """
        \(scriptPrologue(contentLimit: contentLimit))
        set out to ""
        tell application "Mail"
            set msgs to messages of inbox
            set total to count of msgs
        end tell
        set n to \(count)
        if n > total then set n to total
        repeat with i from 1 to n
            tell application "Mail" to set m to item i of msgs
            set out to out & my serializeMessage(m, fs, rs, \(contentLimit))
        end repeat
        return out
        """
    }

    /// One message by RFC message id.
    static func getMessageScript(messageID: String, contentLimit: Int) -> String {
        """
        \(scriptPrologue(contentLimit: contentLimit))
        tell application "Mail"
            set matches to (messages of inbox whose message id is "\(appleScriptEscaped(messageID))")
        end tell
        if (count of matches) is 0 then return ""
        return my serializeMessage(item 1 of matches, fs, rs, \(contentLimit))
        """
    }

    /// Inbox messages (all accounts) whose subject or sender contains
    /// `query`, newest first. Mail evaluates the `whose` clause itself and
    /// treats `contains` case-insensitively; the unified inbox is ordered
    /// newest-first, so `item 1 thru n` of the matches keeps the query cheap
    /// even when a huge mailbox produces many hits.
    static func searchMessagesScript(query: String, count: Int, contentLimit: Int) -> String {
        """
        \(scriptPrologue(contentLimit: contentLimit))
        set q to "\(appleScriptEscaped(query))"
        tell application "Mail"
            set msgs to (messages of inbox whose subject contains q or sender contains q)
            set total to count of msgs
        end tell
        set n to \(count)
        if n > total then set n to total
        set out to ""
        repeat with i from 1 to n
            tell application "Mail" to set m to item i of msgs
            set out to out & my serializeMessage(m, fs, rs, \(contentLimit))
        end repeat
        return out
        """
    }

    /// All inbox messages received in the last `secondsAgo` seconds.
    static func messagesSinceScript(secondsAgo: Int, contentLimit: Int) -> String {
        """
        \(scriptPrologue(contentLimit: contentLimit))
        set cutoff to (current date) - \(secondsAgo)
        tell application "Mail"
            set msgs to (messages of inbox whose date received > cutoff)
        end tell
        set out to ""
        repeat with m in msgs
            set out to out & my serializeMessage(m, fs, rs, \(contentLimit))
        end repeat
        return out
        """
    }
}
