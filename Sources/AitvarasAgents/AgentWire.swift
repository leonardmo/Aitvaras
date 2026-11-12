import Foundation

/// Correlates only client requests. Server requests remain owned by a run and
/// must be answered explicitly. No raw provider error text escapes this layer.
actor AgentWire {
    enum Format: Sendable { case claude, codex }
    private let process: StreamingProcess
    private let format: Format
    private var nextID: Int64 = 0
    private var pending: [AgentRequestID: CheckedContinuation<JSONValue, Error>] = [:]
    private var timers: [AgentRequestID: Task<Void, Never>] = [:]
    private var reader: Task<Void, Never>?
    private var failure: AgentFailure?
    private var receive: (@Sendable (JSONValue, AgentRequestID?) async -> Void)?
    private var disconnected: (@Sendable (AgentFailure) async -> Void)?

    init(process: StreamingProcess, format: Format) { self.process = process; self.format = format }

    deinit { reader?.cancel(); process.terminate() }

    func open(receive: @escaping @Sendable (JSONValue, AgentRequestID?) async -> Void,
              disconnected: @escaping @Sendable (AgentFailure) async -> Void) throws {
        try process.start()
        self.receive = receive; self.disconnected = disconnected
        reader = Task { [weak self, process] in
            do {
                for try await line in process.lines {
                    guard let value = JSONValue.parse(line), case .object = value else {
                        throw AgentFailure.invalidRequest
                    }
                    // Decode IDs separately: JSONValue deliberately uses Double,
                    // whereas RPC IDs must preserve every Int64 bit.
                    let ids = try JSONDecoder().decode(WireIDs.self, from: Data(line.utf8))
                    await self?.consume(value, ids: ids)
                }
                let code = try await process.waitForExit()
                await self?.fail(.crashed(exitCode: code))
            } catch {
                await self?.fail((error as? AgentFailure) ?? .crashed(exitCode: nil))
            }
        }
    }

    func write(_ value: JSONValue) async throws {
        if let failure { throw failure }
        do { try await process.write(line: value.jsonString) }
        catch { await fail(.crashed(exitCode: nil)); throw AgentFailure.crashed(exitCode: nil) }
    }

    func request(_ method: String, _ parameters: JSONValue = .object([:]),
                 id explicitID: AgentRequestID? = nil, timeout: Duration = .seconds(30),
                 failOnTimeout: Bool = true) async throws -> JSONValue {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard pending.count < 64 else { throw AgentFailure.invalidTransition }
        nextID += 1
        let id = explicitID ?? (format == .claude ? .string("client-\(nextID)") : .integer(nextID))
        guard pending[id] == nil else { throw AgentFailure.invalidRequest }
        let frame: JSONValue
        if format == .claude {
            var request = parameters.objectValue ?? [:]; request["subtype"] = .string(method)
            frame = .object(["type": .string("control_request"), "request_id": id.json, "request": .object(request)])
        } else {
            frame = .object(["id": id.json, "method": .string(method), "params": parameters])
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                pending[id] = continuation
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.expire(id, failOnTimeout: failOnTimeout)
                }
                Task { [weak self] in
                    do { try await self?.writePending(frame, id: id) }
                    catch { await self?.reject(id, error: error) }
                }
            }
        } onCancel: { Task { await self.reject(id, error: CancellationError()) } }
    }

    private func consume(_ value: JSONValue, ids: WireIDs) async {
        guard failure == nil else { return }
        let isResponse = format == .claude ? value["type"]?.stringValue == "control_response"
            : value["method"] == nil && (value["result"] != nil || value["error"] != nil)
        if isResponse {
            let response = format == .claude ? value["response"] ?? .null : value
            guard let id = format == .claude ? ids.response?.request_id : ids.id,
                  let continuation = pending.removeValue(forKey: id) else { return }
            timers.removeValue(forKey: id)?.cancel()
            if response["error"] != nil || response["subtype"]?.stringValue == "error" {
                continuation.resume(throwing: AgentFailure.unknown)
            } else {
                continuation.resume(returning: response[format == .claude ? "response" : "result"] ?? .null)
            }
        } else {
            let id = format == .claude ? ids.request_id : ids.id ?? (value["method"]?.stringValue == "serverRequest/resolved" ? ids.params?.requestId : nil)
            await receive?(value, id)
        }
    }

    private func writePending(_ frame: JSONValue, id: AgentRequestID) async throws {
        guard pending[id] != nil else { return }
        try await write(frame)
    }

    private func reject(_ id: AgentRequestID, error: Error) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
    private func expire(_ id: AgentRequestID, failOnTimeout: Bool) async {
        guard pending[id] != nil else { return }
        // Optional read-only recovery must not dispose a healthy transport.
        if !failOnTimeout { reject(id, error: AgentFailure.offline); return }
        // A timed out state-changing call leaves the connection uncertain.
        await fail(.offline)
    }
    private func fail(_ error: AgentFailure) async {
        guard failure == nil else { return }
        failure = error
        let waiters = pending; pending.removeAll()
        timers.values.forEach { $0.cancel() }; timers.removeAll()
        waiters.values.forEach { $0.resume(throwing: error) }
        process.terminate()
        await disconnected?(error)
    }
    func close() async throws {
        await fail(.crashed(exitCode: nil))
        receive = nil; disconnected = nil
        try await process.shutdown(grace: .zero)
        reader?.cancel(); reader = nil
    }
}

private struct WireIDs: Decodable {
    var id: AgentRequestID?
    var request_id: AgentRequestID?
    var response: Response?
    var params: Parameters?
    struct Parameters: Decodable { var requestId: AgentRequestID? }
    struct Response: Decodable { var request_id: AgentRequestID? }
}

extension AgentRequestID {
    var json: JSONValue {
        switch self {
        case .string(let value): return .string(value)
        case .integer(let value): return .number(Double(value))
        }
    }
    /// JSONValue cannot represent all Int64 IDs; substitute the encoded ID in
    /// replies via this encoder instead (see writeResponse below).
    var encoded: String {
        switch self {
        case .integer(let value): return String(value)
        case .string(let value): return JSONValue.string(value).jsonString
        }
    }
}

extension AgentWire {
    func writeResponse(id: AgentRequestID, result: JSONValue?, error: Bool = false) async throws {
        if let failure { throw failure }
        let body = error ? "\"error\":{\"code\":-32601,\"message\":\"Unsupported request\"}"
            : "\"result\":\((result ?? .null).jsonString)"
        do { try await process.write(line: "{\"id\":\(id.encoded),\(body)}") }
        catch { await fail(.crashed(exitCode: nil)); throw AgentFailure.crashed(exitCode: nil) }
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var int: Int? { doubleValue.flatMap(Int.init(exactly:)) }
    var date: Date? { doubleValue.map { Date(timeIntervalSince1970: $0) } }
}

func agentQuestions(_ value: JSONValue, claude: Bool) throws -> [AgentQuestion] {
    guard let values = value.arrayValue else { throw AgentFailure.invalidRequest }
    let questions = try values.map { question in
        guard let prompt = question["question"]?.stringValue,
              let id = claude ? prompt : question["id"]?.stringValue else { throw AgentFailure.invalidRequest }
        if let options = question["options"], options != .null, options.arrayValue == nil { throw AgentFailure.invalidRequest }
        let options = try (question["options"]?.arrayValue ?? []).map { option in
            guard let label = option["label"]?.stringValue, let description = option["description"]?.stringValue else {
                throw AgentFailure.invalidRequest
            }
            return AgentQuestion.Option(label: label, description: description)
        }
        return AgentQuestion(id: id, prompt: prompt, options: options,
            allowsMultiple: claude && question["multiSelect"]?.boolValue == true,
            allowsFreeText: claude || options.isEmpty || question["isOther"]?.boolValue == true,
            isSecret: question["isSecret"]?.boolValue ?? false)
    }
    try AgentQuestionState.validateQuestions(questions)
    return questions
}

let subscriptionCapabilities: Set<AgentCapability> = [.thinking, .tools, .approvals, .plans, .questions, .followups, .history]
