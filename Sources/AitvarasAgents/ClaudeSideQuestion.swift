import Foundation

/// Deliberately outside AgentRun: no journal, transcript, MCP runtime file or
/// native session persistence. The caller audits metadata only.
enum ClaudeSideQuestion {
    static func arguments(_ configuration: AgentSessionConfiguration) throws -> [String] {
        guard let session = configuration.resume, session.provider == .claude,
              UUID(uuidString: session.nativeID) != nil else { throw AgentConversationError.unavailable }
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--resume", session.nativeID,
            "--fork-session", "--no-session-persistence", "--tools", "", "--settings", "{\"disableAllHooks\":true}",
            "--strict-mcp-config"]
        arguments += ["--model", ChatSettings.claudeModel(configuration.model)]
        arguments += ["--effort", ChatSettings.claudeEffort(configuration.effort)]
        return arguments
    }

    static func run(executable: URL, environment: [String: String], configuration: AgentSessionConfiguration,
                    question: String, timeout: Duration) async throws -> String {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 16_384, !question.contains("\0") else { throw AgentFailure.invalidRequest }
        let process = StreamingProcess(executable: executable, arguments: try arguments(configuration),
            currentDirectory: configuration.directory, environment: environment)
        try Task.checkCancellation(); try process.start()
        do {
            let answer = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        // Keep question text out of the CLI's leading slash
                        // command / bang-command parser, including repo skills.
                        try await process.write(line: "Answer this side question using the resumed conversation. The question is JSON-quoted text: " + JSONValue.string(question).jsonString)
                        process.closeInput()
                        var text: [String] = [], bytes = 0, succeeded = false
                        for try await line in process.lines {
                            try Task.checkCancellation()
                            bytes += line.utf8.count
                            guard bytes <= 262_144, let value = JSONValue.parse(line) else { throw AgentConversationError.invalidResponse }
                            switch value["type"]?.stringValue {
                            case "system":
                                if value["subtype"]?.stringValue == "init", value["apiKeySource"]?.stringValue != "none" { throw AgentFailure.unsupported }
                                if value["subtype"]?.stringValue?.hasPrefix("hook_") == true { throw AgentConversationError.invalidResponse }
                            case "assistant":
                                for block in value["message"]?["content"]?.arrayValue ?? [] {
                                    guard block["type"]?.stringValue != "tool_use" else { throw AgentConversationError.invalidResponse }
                                    if block["type"]?.stringValue == "text", let part = block["text"]?.stringValue { text.append(part) }
                                }
                            case "result":
                                guard !succeeded, value["is_error"]?.boolValue == false else { throw AgentConversationError.invalidResponse }
                                succeeded = true
                                if text.isEmpty, let result = value["result"]?.stringValue { text.append(result) }
                            case "control_request": throw AgentConversationError.invalidResponse
                            default: break
                            }
                        }
                        guard try await process.waitForExit() == 0, succeeded, !text.isEmpty else { throw AgentConversationError.invalidResponse }
                        return AgentTranscriptContent.bounded(text.joined(separator: "\n"))
                    } onCancel: { process.terminate() }
                }
                group.addTask {
                    try await Task.sleep(for: min(timeout, .seconds(120)))
                    throw AgentConversationError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try await process.shutdown(grace: .zero)
            return answer
        } catch {
            try? await process.shutdown(grace: .zero)
            if Task.isCancelled { throw CancellationError() }
            if let failure = error as? AgentConversationError { throw failure }
            if let failure = error as? AgentFailure { throw failure }
            throw AgentConversationError.invalidResponse
        }
    }
}
