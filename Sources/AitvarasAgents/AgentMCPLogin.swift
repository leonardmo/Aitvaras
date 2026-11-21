import Foundation

/// Login output is transient. Only a validated browser URL crosses this boundary;
/// raw output, URLs and provider-owned credentials never enter setup or audits.
enum AgentMCPLogin {
    static func run(executable: URL, name: String, directory: URL, environment: [String: String],
                    timeout: Duration, onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        try Task.checkCancellation()
        try AgentMCPConfiguration.validateName(name)
        // `mcp login` refuses a `.mcp.json` server the CLI itself has not
        // approved. Aitvaras keeps its approvals out of the CLI's files, and the
        // coordinator only offers sign-in for servers approved in Aitvaras, so
        // pass that approval for this one call. Harmless for other sources.
        let approval = String(decoding: try JSONSerialization.data(withJSONObject: ["enabledMcpjsonServers": [name]]), as: UTF8.self)
        let process = StreamingProcess(executable: executable, arguments: ["--settings", approval, "mcp", "login", "--", name],
            currentDirectory: directory, environment: environment)
        // Claude requires a terminal to keep its loopback listener active.
        // Give it enough columns to print the authorization URL on one line.
        try process.startInPTY(columns: 16_384)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        var delivered = false
                        for try await line in process.lines {
                            try Task.checkCancellation()
                            if !delivered, let url = browserURL(in: line) {
                                delivered = true
                                await onBrowserURL(url)
                            }
                        }
                        guard try await process.waitForExit() == 0 else { throw AgentFailure.authRequired }
                    } onCancel: { process.terminate() }
                }
                group.addTask {
                    try await Task.sleep(for: min(timeout, .seconds(300)))
                    throw ProviderSignInError.timedOut
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            try Task.checkCancellation()
            try await process.shutdown(grace: .zero)
        } catch {
            try? await process.shutdown(grace: .zero)
            if Task.isCancelled { throw CancellationError() }
            if error is ProviderSignInError { throw error }
            throw AgentFailure.authRequired
        }
    }
    // Remove control strings (including OSC hyperlinks), CSI sequences, and
    // other ESC commands before looking for the URL in the displayed text.
    private static let terminalEscapes = #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\|$)|\x1B[PX^_][^\x1B]*(?:\x1B\\|$)|\x1B\[[0-?]*[ -/]*[@-~]|\x1B[ -/]*[0-~]"#

    private static func browserURL(in text: String) -> URL? {
        let visible = text.replacingOccurrences(of: terminalEscapes, with: "", options: .regularExpression)
        for word in visible.split(whereSeparator: \.isWhitespace) {
            let candidate = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>(),"))
            guard let url = URL(string: candidate), (try? ProviderSignIn.validate(url)) != nil else { continue }
            return url
        }
        return nil
    }
}
