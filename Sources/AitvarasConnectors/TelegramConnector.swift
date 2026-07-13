import Foundation
import AitvarasCore
import AitvarasStore

/// Telegram bot for urgent phone notifications (D5): when mail is urgent and
/// the user is away from the Mac, Aitvaras pushes to the phone. Sending to the
/// user's own chat is a self-notification, hence `reversibleWrite` — the
/// D13 confirmation card would defeat the purpose ("notify me while I'm away").
///
/// Secrets: bot token in the Keychain (`telegram.botToken`); the numeric chat
/// id is not a secret and lives in the kv store (`telegram.chatID`).
public actor TelegramConnector: Connector {
    public nonisolated let id = "telegram"
    public nonisolated let displayName = "Telegram"

    public static let tokenKeychainKey = "telegram.botToken"
    public static let chatIDKey = "telegram.chatID"

    private let keychain: KeychainStore
    private let stores: Stores

    public init(keychain: KeychainStore, stores: Stores) {
        self.keychain = keychain
        self.stores = stores
    }

    public nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "notify_phone",
            description: "Send an urgent notification to the user's phone via their Telegram bot. Use only for things that cannot wait until they are back at the Mac.",
            parametersJSON: """
            {"type":"object","properties":{"text":{"type":"string","description":"The notification text"}},"required":["text"]}
            """,
            risk: .reversibleWrite
        )
    ]

    public func health() async -> ConnectorHealth {
        guard let token = try? keychain.get(Self.tokenKeychainKey), !token.isEmpty else {
            return .needsAuthentication(message: "No Telegram bot token. Create a bot with @BotFather and paste the token in Settings → Connectors → Telegram.")
        }
        guard let chatID = try? stores.value(forKey: Self.chatIDKey), !chatID.isEmpty else {
            return .needsAuthentication(message: "Telegram chat not linked. Send any message to your bot, then use \"Discover chat\" in Settings → Connectors → Telegram.")
        }
        return .ready
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        guard toolName == "notify_phone" else {
            throw ConnectorError("Telegram connector has no tool named '\(toolName)'.")
        }
        let args = try ToolArgs(json: argumentsJSON)
        let text = try args.requiredString("text")
        try await sendMessage(String(text.prefix(4000)))   // Telegram hard limit is 4096
        return "Notification sent to phone."
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        AsyncStream { $0.finish() }   // outbound-only connector
    }

    // MARK: - Settings-UI helpers (not exposed as tools)

    /// Reads the bot's pending updates and stores the chat id of the first
    /// message found. The user just has to text their bot once beforehand.
    @discardableResult
    public func discoverChatID() async throws -> String {
        let data = try await api(method: "getUpdates", body: nil)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["ok"] as? Bool == true,
            let updates = root["result"] as? [[String: Any]]
        else {
            throw ConnectorError("Unexpected getUpdates response from Telegram.")
        }
        for update in updates {
            if let message = update["message"] as? [String: Any],
               let chat = message["chat"] as? [String: Any],
               let chatID = chat["id"] as? NSNumber {
                let value = chatID.stringValue
                try stores.setValue(value, forKey: Self.chatIDKey)
                return value
            }
        }
        throw ConnectorError("No messages found. Send any message to your bot in Telegram first, then try again.")
    }

    /// Sends a test message so the user can verify the wiring from Settings.
    public func testMessage() async throws {
        try await sendMessage("Aitvaras test message — the Telegram connection works.")
    }

    // MARK: - Telegram Bot API

    private func sendMessage(_ text: String) async throws {
        guard let chatID = try? stores.value(forKey: Self.chatIDKey), !chatID.isEmpty else {
            throw ConnectorError("Telegram chat id missing — run chat discovery in Settings first.")
        }
        let body = try JSONSerialization.data(withJSONObject: ["chat_id": chatID, "text": text])
        let data = try await api(method: "sendMessage", body: body)
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["ok"] as? Bool == true
        else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw ConnectorError("Telegram rejected the message: \(snippet)")
        }
    }

    private func api(method: String, body: Data?) async throws -> Data {
        guard let token = try? keychain.get(Self.tokenKeychainKey), !token.isEmpty else {
            throw ConnectorError("Telegram bot token missing — paste it in Settings first.")
        }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw ConnectorError("Could not build Telegram API URL.")
        }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw ConnectorError("Telegram API \(method) failed with HTTP \(http.statusCode): \(snippet)")
        }
        return data
    }
}
