import Foundation
import AitvarasConnectors

/// Drafts a D17 connector manifest by delegating to the Claude Code CLI
/// (D14): the big model reads the API docs and produces the JSON; the
/// user reviews before anything is saved or executed. Local model never
/// has to struggle with unfamiliar APIs.
enum ManifestDrafter {
    static func isAvailable() -> Bool {
        DelegateConnector.findAgent() != nil
    }

    static let manifestSchemaExplainer = """
    A Aitvaras connector manifest is JSON with this shape:
    {
      "id": "short-lowercase-id",
      "displayName": "Human Name",
      "baseURL": "https://api.example.com",
      "auth": {"type": "bearer"|"header"|"query"|"basic"|"none",
               "keychainKey": "exampleservice.token",       // omit for none
               "headerName": "X-Api-Key",                    // for type header
               "valuePrefix": "Token ",                      // optional prefix
               "queryParam": "api_key"},                     // for type query
      "tools": [
        {"name": "tool_name", "description": "What it returns, for an LLM to decide when to call it.",
         "method": "GET", "path": "/v1/thing/{id}?fixed=param",
         "parametersJSON": "{\\"type\\":\\"object\\",\\"properties\\":{\\"id\\":{\\"type\\":\\"string\\"}},\\"required\\":[\\"id\\"]}",
         "risk": "read"}
      ],
      "triggers": [
        {"name": "something_changed", "method": "GET", "path": "/v1/status",
         "intervalSeconds": 900, "watchPath": "data.0.value",
         "titleTemplate": "Value changed: {value}"}
      ]
    }
    Rules: {placeholders} in path come from tool arguments; leftover arguments become
    query parameters (GET) or a JSON body (POST). risk must be "read" for anything
    that only fetches data, "reversibleWrite" for easily-undoable writes,
    "confirmable" for anything else. Prefer read-only tools. triggers are optional.
    """

    /// Ask Claude to produce a manifest. Returns the raw JSON string.
    static func draft(description: String, docsURL: String) async throws -> String {
        guard let agent = DelegateConnector.findAgent(), agent.kind == .claude else {
            throw NSError(domain: "ManifestDrafter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Claude CLI not found — install with: npm install -g @anthropic-ai/claude-code"
            ])
        }

        let prompt = """
        Create a Aitvaras connector manifest for this API.

        \(manifestSchemaExplainer)

        User's description of what they want: \(description)
        \(docsURL.isEmpty ? "" : "API documentation to consult (fetch and read it): \(docsURL)")

        Reply with ONLY the manifest JSON — no markdown fences, no commentary.
        Include only tools you are confident about from the docs. All secrets
        must be referenced via keychainKey, never inlined.
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: agent.path)
        process.arguments = [
            "-p", prompt,
            "--output-format", "json",
            "--max-turns", "12",
            "--allowedTools", "WebFetch,WebSearch"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DispatchQueue.global().async {
                let collected = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: collected)
            }
        }

        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = envelope["result"] as? String else {
            throw NSError(domain: "ManifestDrafter", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Claude returned no parseable result (is the CLI logged in? Run 'claude' once in a terminal)."
            ])
        }
        // Strip accidental code fences.
        return result
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
