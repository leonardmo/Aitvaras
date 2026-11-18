import Foundation

/// Login output is transient. Only a validated browser URL crosses this boundary;
/// raw output, URLs and provider-owned credentials never enter setup or audits.
enum AgentMCPLogin {
    static func run(executable: URL, name: String, directory: URL, environment: [String: String],
                    timeout: Duration, onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        try AgentMCPConfiguration.validateName(name)
        // `mcp login` refuses a `.mcp.json` server the CLI itself has not
        // approved. Aitvaras keeps its approvals out of the CLI's files, and the
        // coordinator only offers sign-in for servers approved in Aitvaras, so
        // pass that approval for this one call. Harmless for other sources.
        let approval = String(decoding: try JSONSerialization.data(withJSONObject: ["enabledMcpjsonServers": [name]]), as: UTF8.self)
        let process = StreamingProcess(executable: executable, arguments: ["--settings", approval, "mcp", "login", "--", name],
            currentDirectory: directory, environment: environment)
        let urls = AgentMCPLoginURLs()
        try process.start()
        do {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        for try await line in process.lines {
                            await urls.deliver(in: line, callback: onBrowserURL)
                        }
                        guard try await process.waitForExit() == 0 else { throw AgentFailure.authRequired }
                        return true
                    } onCancel: { process.terminate() }
                }
                group.addTask {
                    while !Task.isCancelled {
                        await urls.deliver(in: process.stderrText, callback: onBrowserURL)
                        if !process.isRunning { return false }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    return false
                }
                group.addTask {
                    try await Task.sleep(for: min(timeout, .seconds(300)))
                    throw ProviderSignInError.timedOut
                }
                defer { group.cancelAll() }
                // The stderr observer finishing does not establish login success.
                while let completed = try await group.next() {
                    if completed { return }
                }
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
}

private actor AgentMCPLoginURLs {
    private var delivered = false
    func deliver(in text: String, callback: @Sendable (URL) async -> Void) async {
        guard !delivered else { return }
        for word in text.split(whereSeparator: \.isWhitespace) {
            let candidate = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>(),"))
            guard let url = URL(string: candidate), (try? ProviderSignIn.validate(url)) != nil else { continue }
            delivered = true
            await callback(url)
            return
        }
    }
}
