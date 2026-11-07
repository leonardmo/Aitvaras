import Foundation

/// One sandboxed server for this Aitvaras profile; native sessions persist in
/// its isolated XDG data store. A server never silently gains write authority.
public actor OpencodeBackend: AgentBackend {
    public static let capabilities: Set<AgentCapability> = [.thinking, .tools, .approvals, .followups]
    private let executable: URL?
    private let transport: any OpencodeTransport
    private let catalog: @Sendable () async throws -> [AgentModel]
    private var roots: [String]?
    private var serverModels: [AgentModel] = []
    private var runs: [String: OpencodeRun] = [:]
    private var reader: Task<Void, Never>?
    private var starting = false
    private var generation = UUID()
    private var shutdownTask: Task<Void, Never>?

    public init(executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                configuration: OpencodeConfiguration = .init()) {
        let found = ProviderLocator.executable(for: .local, environment: environment,
            overrides: executable.map { [.local: $0] } ?? [:])
        self.executable = found
        transport = OpencodeHTTPTransport(executable: found ?? URL(fileURLWithPath: "/usr/bin/false"),
            environment: environment, configuration: configuration)
        catalog = { try await OpencodeConfiguration.installedModels() }
    }
    init(transport: any OpencodeTransport, catalog: @escaping @Sendable () async throws -> [AgentModel]) {
        executable = URL(fileURLWithPath: "/usr/bin/true"); self.transport = transport; self.catalog = catalog
    }
    public func status() async throws -> AgentStatus {
        guard executable != nil else { return .init(installed: false, authentication: .unavailable, capabilities: []) }
        do {
            let models = try await models()
            return .init(installed: true, authentication: models.isEmpty ? .unavailable : .local,
                         capabilities: models.isEmpty ? [] : Self.capabilities)
        } catch is CancellationError { throw CancellationError() }
        catch { return .init(installed: true, authentication: .unavailable, capabilities: []) }
    }
    public func models() async throws -> [AgentModel] { try await catalog().filter { OpencodeConfiguration.isLocalModel($0.id) } }
    public func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    public func start(_ configuration: AgentSessionConfiguration) async throws -> any AgentRun {
        guard executable != nil else { throw AgentFailure.notInstalled }
        guard !starting, shutdownTask == nil else { throw AgentFailure.invalidTransition }
        starting = true
        defer { starting = false }
        let startGeneration = generation
        let models = try await models()
        guard startGeneration == generation else { throw AgentFailure.invalidTransition }
        guard configuration.effort == nil, models.contains(where: { $0.id == configuration.model }) else { throw AgentFailure.unsupported }
        let projects = [configuration.directory] + configuration.additionalDirectories
        let requestedRoots = try OpencodeConfiguration.writeRoots(projects)
        if roots != requestedRoots || serverModels != models {
            for run in runs.values where await run.isActive { throw AgentFailure.invalidTransition }
            if roots != nil { await shutdown() }
            let openingGeneration = generation
            do {
                try await transport.open(projects: projects, models: models)
                guard openingGeneration == generation else { throw AgentFailure.invalidTransition }
                let events = try await transport.subscribe()
                guard openingGeneration == generation else { throw AgentFailure.invalidTransition }
                roots = requestedRoots; serverModels = models
                let generation = self.generation
                reader = Task { [weak self] in
                    do {
                        for try await value in events { await self?.receive(value, generation: generation) }
                        await self?.disconnected(generation: generation)
                    } catch { await self?.disconnected(generation: generation) }
                }
            } catch { await transport.close(); throw (error as? AgentFailure) ?? .offline }
        }
        let sessionGeneration = generation
        let nativeID: String
        let model: JSONValue = .object(["id": .string(configuration.model), "providerID": .string("ollama")])
        if let resume = configuration.resume, resume.profile == OpencodeConfiguration.profile {
            guard resume.provider == .local, resume.host == "local", Self.validID(resume.nativeID), runs[resume.nativeID] == nil else { throw AgentFailure.invalidRequest }
            let value = try await transport.request("api/session/\(resume.nativeID)", method: "GET", body: nil)["data"]
            guard value?["id"]?.stringValue == resume.nativeID,
                  value?["location"]?["directory"]?.stringValue.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == configuration.directory.resolvingSymlinksInPath().path,
                  value?["model"]?["providerID"]?.stringValue == "ollama" else { throw AgentFailure.invalidRequest }
            nativeID = resume.nativeID
            _ = try await transport.request("api/session/\(nativeID)/model", method: "POST", body: .object(["model": model]))
            _ = try await transport.request("api/session/\(nativeID)", method: "PATCH", body: .object(["permissions": OpencodeConfiguration.permissions(mode: configuration.mode)]))
        } else {
            // Old text-only Local IDs are not native opencode sessions.
            if let resume = configuration.resume, resume.provider != .local { throw AgentFailure.invalidRequest }
            let value = try await transport.request("api/session", method: "POST", body: .object([
                "model": model, "location": .object(["directory": .string(configuration.directory.resolvingSymlinksInPath().path)]),
                "permissions": OpencodeConfiguration.permissions(mode: configuration.mode)]))
            guard let id = value["data"]?["id"]?.stringValue, Self.validID(id), runs[id] == nil else { throw AgentFailure.invalidRequest }
            nativeID = id
        }
        guard sessionGeneration == generation else { throw AgentFailure.invalidTransition }
        let session = AgentSessionID(provider: .local, profile: OpencodeConfiguration.profile, nativeID: nativeID)
        let run = OpencodeRun(transport: transport, session: session, configuration: configuration,
            release: { [weak self] id in await self?.release(nativeID, id: id) })
        runs[nativeID] = run
        await run.started()
        return run
    }
    private static func validID(_ id: String) -> Bool {
        id.hasPrefix("ses") && id.utf8.count < 256 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }
    }
    private func release(_ nativeID: String, id: UUID) async {
        guard runs[nativeID]?.id == id else { return }
        runs.removeValue(forKey: nativeID)
        if runs.isEmpty { await shutdown() }
    }
    private func receive(_ value: JSONValue, generation: UUID) async {
        guard generation == self.generation else { return }
        if let session = opencodeEventSession(value) {
            if let run = runs[session] { await run.receive(value) }
            return
        }
        // Only protocol-defined input waits may interrupt an unroutable turn.
        // Informational and unknown events never establish a user-input wait.
        guard opencodeBlocksOnUserInput(value) else { return }
        for run in Array(runs.values) where await run.isActive { await run.unroutableEvent() }
    }
    private func disconnected(generation: UUID) async {
        guard generation == self.generation else { return }
        await shutdown()
    }
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        guard starting || roots != nil || reader != nil || !runs.isEmpty else { return }
        generation = UUID()
        reader?.cancel(); reader = nil
        let current = runs; runs.removeAll(); roots = nil
        let cleanup = Task { [transport] in await transport.close() }
        shutdownTask = cleanup
        for run in current.values { await run.disconnected() }
        await cleanup.value
        shutdownTask = nil
    }
    // The Aitvaras transcript is authoritative. We don't advertise native history
    // until opencode's complete-branch reconciliation is implemented.
    public func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    public func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}

actor OpencodeRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let transport: any OpencodeTransport
    private let session: AgentSessionID
    private let configuration: AgentSessionConfiguration
    private let release: @Sendable (UUID) async -> Void
    private var inputID: UUID?
    private var queued: [String: UUID] = [:]
    private var requests: [AgentRequestID: AgentRequest] = [:]
    private var forms: [AgentRequestID: OpencodeForm] = [:]
    private var seenForms: Set<String> = []
    private var tools: [String: AgentTool] = [:]
    private var mode: AgentMode
    private var closed = false
    private var sending = false
    private var draining = false
    private var rejectingUnknown = false
    private var buffered: [JSONValue] = []
    var isActive: Bool { inputID != nil || sending || !queued.isEmpty }

    init(transport: any OpencodeTransport, session: AgentSessionID, configuration: AgentSessionConfiguration,
         release: @escaping @Sendable (UUID) async -> Void) {
        self.transport = transport; self.session = session; self.configuration = configuration; self.release = release
        mode = configuration.mode
        (events, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(4096))
    }
    func started() { emit(.sessionStarted(session)) }
    func unroutableEvent() async {
        // Use normal buffering so a slow prompt acknowledgement remains first.
        await receive(.object(["type": .string("opencode.unroutable.wait"),
            "data": .object(["sessionID": .string(session.nativeID)])]))
    }
    private func scope(item: String? = nil, input: UUID? = nil) -> AgentEventScope {
        .init(runID: id, session: session, inputID: input ?? inputID, itemID: item)
    }
    private func emit(_ kind: AgentEvent.Kind, item: String? = nil, input: UUID? = nil) {
        guard !closed else { return }
        guard case .enqueued = continuation.yield(.init(scope: scope(item: item, input: input), kind: kind)) else {
            closed = true; continuation.finish(throwing: AgentFailure.invalidTransition)
            Task { [transport, release, id] in
                await transport.close(); await release(id)
            }
            return
        }
    }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed, !rejectingUnknown, !isActive else { throw AgentFailure.invalidTransition }
        try input.validateComposerInput(provider: .local)
        sending = true; inputID = input.id
        defer { sending = false }
        do {
            try await willDeliver()
            guard !closed, inputID == input.id else { throw AgentFailure.invalidTransition }
            try await prompt(input, delivery: nil)
            sending = false; await drainBuffered()
        } catch { if inputID == input.id { inputID = nil }; throw error }
    }
    func followup(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed, !rejectingUnknown, !sending, inputID != nil, queued.count < 32 else { throw AgentFailure.invalidTransition }
        try input.validateComposerInput(provider: .local)
        let key = "msg_" + input.id.uuidString
        guard queued[key] == nil else { throw AgentFailure.invalidRequest }
        queued[key] = input.id; sending = true
        defer { sending = false }
        do {
            try await willDeliver()
            guard !closed else { throw AgentFailure.invalidTransition }
            try await prompt(input, delivery: "queue")
            sending = false; await drainBuffered()
        } catch { queued.removeValue(forKey: key); throw error }
    }
    private func prompt(_ input: AgentInput, delivery: String?) async throws {
        var body: [String: JSONValue] = ["id": .string("msg_" + input.id.uuidString), "text": .string(input.text)]
        if !configuration.instructions.isEmpty {
            body["text"] = .string("[Aitvaras project instructions]\n" + configuration.instructions + "\n[End project instructions]\n" + input.text)
        }
        if let delivery { body["delivery"] = .string(delivery) }
        let result = try await transport.request("api/session/\(session.nativeID)/prompt", method: "POST", body: .object(body))
        guard result["data"]?["id"]?.stringValue == "msg_" + input.id.uuidString,
              result["data"]?["sessionID"]?.stringValue == session.nativeID else { throw AgentFailure.invalidRequest }
        emit(.delivery(.acknowledged), input: input.id)
    }
    func respond(to request: AgentRequest, with response: AgentResponse) async throws {
        guard !closed, request.scope.runID == id, request.scope.inputID == inputID,
              requests[request.id] == request, case .string(let requestID) = request.id else { throw AgentFailure.invalidRequest }
        let path: String, method: String, body: JSONValue?
        switch request.kind {
        case .questions:
            guard let form = forms[request.id] else { throw AgentFailure.invalidRequest }
            switch response {
            case .answers(let answers):
                path = "api/session/\(session.nativeID)/form/\(requestID)/reply"
                method = "POST"; body = try form.reply(answers)
            case .deny, .unsupported:
                path = "api/session/\(session.nativeID)/form/\(requestID)"; method = "DELETE"; body = nil
            default: throw AgentFailure.invalidRequest
            }
        case .permission:
            let decision: String
            switch response {
            case .allow(updatedInput: nil): decision = "once"
            case .deny, .unsupported: decision = "reject"
            default: throw AgentFailure.invalidRequest
            }
            path = "api/session/\(session.nativeID)/permission/\(requestID)/reply"
            method = "POST"; body = .object(["decision": .string(decision)])
        default: throw AgentFailure.invalidRequest
        }
        requests.removeValue(forKey: request.id); forms.removeValue(forKey: request.id)
        do { _ = try await transport.request(path, method: method, body: body) }
        catch { await abort(); throw error }
        emit(.requestResolved(request.id), item: request.scope.itemID)
    }
    func setMode(_ mode: AgentMode) async throws {
        guard !closed, !isActive else { throw AgentFailure.invalidTransition }
        _ = try await transport.request("api/session/\(session.nativeID)", method: "PATCH", body: .object(["permissions": OpencodeConfiguration.permissions(mode: mode)]))
        self.mode = mode; emit(.modeChanged(mode))
    }
    func interrupt() async throws {
        guard !closed else { throw AgentFailure.invalidTransition }
        _ = try await transport.request("api/session/\(session.nativeID)/interrupt", method: "POST", body: .object([:]))
    }
    func shutdown() async throws {
        guard !closed else { return }
        if isActive {
            do { try await interrupt() }
            catch { await abort(); throw error }
        }
        closed = true; requests.removeAll(); forms.removeAll(); queued.removeAll(); buffered.removeAll(); inputID = nil
        continuation.finish(); await release(id)
    }
    func abort() async {
        // Fail closed: a lost HTTP connection cannot prove tool cancellation.
        await transport.close(); disconnected(); await release(id)
    }
    func disconnected() {
        guard !closed else { return }
        closed = true; requests.removeAll(); forms.removeAll(); queued.removeAll(); buffered.removeAll(); inputID = nil
        continuation.finish(throwing: AgentFailure.offline)
    }
    private func end(_ outcome: AgentTurnOutcome) {
        for id in requests.keys { emit(.requestResolved(id)) }; requests.removeAll(); forms.removeAll()
        if inputID != nil { emit(.turnEnded(outcome)) }
        inputID = nil; tools.removeAll(); seenForms.removeAll()
        if outcome != .completed {
            let abandoned = Array(queued.values); queued.removeAll()
            for input in abandoned {
                inputID = input; emit(.inputActivated); emit(.turnEnded(outcome)); inputID = nil
            }
        }
    }
    func receive(_ value: JSONValue) async {
        guard !closed, let data = value["data"],
              opencodeEventSession(value) == session.nativeID else { return }
        let type = value["type"]?.stringValue ?? "opencode.invalid"
        // Reasoning is presentation-only progress, not a delivery receipt. A
        // slow prompt response must not hide it. Keep lifecycle/ack ordering,
        // and never attribute a queued input's reasoning to the previous turn.
        let reasoning = ["session.reasoning.started", "session.reasoning.delta", "session.reasoning.ended"].contains(type)
        let pendingBoundary = buffered.contains {
            let type = $0["type"]?.stringValue ?? ""
            if type == "session.inbox.delivered", let inbox = $0["data"]?["inboxID"]?.stringValue,
               queued[inbox] != nil { return true }
            return ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].contains(type)
        }
        if reasoning, !draining, !pendingBoundary {
            await apply(value, type: type, data: data)
            return
        }
        if sending || draining {
            guard buffered.count < 4096 else { await abort(); return }
            buffered.append(value); return
        }
        await apply(value, type: type, data: data)
    }
    private func drainBuffered() async {
        draining = true
        defer { draining = false }
        while !closed, !buffered.isEmpty {
            let event = buffered.removeFirst()
            if let type = event["type"]?.stringValue, let data = event["data"] {
                await apply(event, type: type, data: data)
            }
        }
    }
    private func apply(_ value: JSONValue, type: String, data: JSONValue) async {
        let item = data["id"]?.stringValue ?? data["assistantMessageID"]?.stringValue
        if type == "session.inbox.delivered", let inbox = data["inboxID"]?.stringValue, let next = queued.removeValue(forKey: inbox) {
            if inputID != nil { end(.completed) }
            inputID = next; emit(.inputActivated); return
        }
        guard inputID != nil else { return }
        switch type {
        case "session.text.delta": if let text = data["delta"]?.stringValue { emit(.textDelta(text), item: item) }
        case "session.reasoning.started": emit(.thinkingDelta(""), item: item)
        case "session.reasoning.delta": if let text = data["delta"]?.stringValue { emit(.thinkingDelta(text), item: item) }
        case "session.reasoning.ended": if let text = data["text"]?.stringValue { emit(.thinkingCompleted(text), item: item) }
        case "session.tool.input.started":
            guard let item, let name = data["name"]?.stringValue, tools.count < 1024 else { await abort(); return }
            tools[item] = .init(name: name, input: .null)
        case "session.tool.input.delta": if let text = data["delta"]?.stringValue { emit(.toolInputDelta(text), item: item) }
        case "session.tool.input.ended":
            if let item, let tool = tools[item], let text = data["text"]?.stringValue {
                tools[item] = .init(name: tool.name, input: JSONValue.parse(text) ?? .string(text))
            }
        case "session.tool.called":
            guard let item, let tool = tools[item] else { await abort(); return }
            let full = AgentTool(name: tool.name, input: data["input"] ?? tool.input)
            tools[item] = full; emit(.toolStarted(full), item: item)
        case "session.tool.success", "session.tool.failed":
            guard let item, tools[item] != nil else { await abort(); return }
            let errorType = data["error"]?["type"]?.stringValue?.lowercased() ?? ""
            let denied = errorType.contains("reject") || errorType.contains("denied")
            let output: JSONValue = denied
                ? .object(["status": .string("declined"), "error": data["error"] ?? .null])
                : data["content"] ?? data["error"] ?? .null
            emit(.toolFinished(output: output, isError: type == "session.tool.failed"), item: item)
            tools.removeValue(forKey: item)
        case "permission.asked":
            guard let requestID = data["id"]?.stringValue, opencodeRequestID(requestID),
                  let action = data["action"]?.stringValue, requests.count < 64,
                  requests[.string(requestID)] == nil else { await abort(); return }
            let toolID = data["source"]?["id"]?.stringValue
            var fallbackInput: [String: JSONValue] = ["resources": data["resources"] ?? .array([])]
            if action == "bash" {
                fallbackInput["command"] = .string((data["resources"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n"))
            }
            let tool = toolID.flatMap { tools[$0] } ?? AgentTool(name: action, input: .object(fallbackInput))
            let request = AgentRequest(id: .string(requestID), scope: scope(item: toolID), kind: .permission(tool))
            requests[request.id] = request; emit(.request(request), item: toolID)
        case "permission.replied":
            if let id = data["requestID"]?.stringValue, requests.removeValue(forKey: .string(id)) != nil { emit(.requestResolved(.string(id))) }
        case "form.created":
            guard let form = data["form"], let formID = form["id"]?.stringValue,
                  formID.hasPrefix("frm_"), opencodeRequestID(formID), requests.count < 64 else {
                await unsupportedEvent(); return
            }
            // Duplicate delivery must not reset the draft or offer a second card.
            guard seenForms.contains(formID) || seenForms.count < 4096 else { await unsupportedEvent(); return }
            guard seenForms.insert(formID).inserted else { return }
            do {
                let parsed = try OpencodeForm(form)
                let request = AgentRequest(id: .string(formID), scope: scope(), kind: .questions(parsed.questions))
                forms[request.id] = parsed; requests[request.id] = request
                emit(.request(request))
            } catch {
                // The schema supplies a cancellation endpoint even for controls
                // this UI cannot render. Let the tool report its cancellation.
                emit(.textDelta("\nNot supported here\n"), item: "opencode.unsupported.\(formID)")
                do { _ = try await transport.request("api/session/\(session.nativeID)/form/\(formID)", method: "DELETE", body: nil) }
                catch { await unsupportedEvent(showMessage: false) }
            }
        case "form.replied", "form.cancelled":
            if let id = data["id"]?.stringValue {
                forms.removeValue(forKey: .string(id))
                if requests.removeValue(forKey: .string(id)) != nil { emit(.requestResolved(.string(id))) }
            }
        case "question.asked", "opencode.unroutable.wait": await unsupportedEvent()
        case "session.execution.succeeded": end(.completed)
        case "session.execution.interrupted": end(.interrupted)
        case "session.execution.failed": end(.failed(.unknown))
        case "session.step.ended", "session.usage.updated":
            if let tokens = data["tokens"] {
                emit(.usage(.init(scope: type == "session.usage.updated" ? .session : .lastCall,
                    inputTokens: opencodeTokenCount(tokens["input"]), outputTokens: opencodeTokenCount(tokens["output"]),
                    cachedInputTokens: opencodeTokenCount(tokens["cache"]?["read"]), cacheWriteInputTokens: opencodeTokenCount(tokens["cache"]?["write"]),
                    thinkingTokens: opencodeTokenCount(tokens["reasoning"]), costUSD: data["cost"]?.doubleValue)))
            }
        case "session.execution.started", "session.inbox.enqueued", "session.inbox.delivered",
             "session.text.started", "session.text.ended", "session.step.started", "session.step.streamed",
             "session.tool.progress", "session.idle",
             "session.retry.scheduled", "session.compaction.started", "session.compaction.delta",
             "session.compaction.ended", "session.compaction.failed", "session.step.failed",
             "session.created", "session.model.selected", "session.permissions",
             "session.renamed", "session.metadata.updated", "session.viewed": break
        default: break // Includes unknown notifications; their payloads stay private.
        }
    }

    private func unsupportedEvent(showMessage: Bool = true) async {
        guard !rejectingUnknown else { return }
        rejectingUnknown = true
        defer { rejectingUnknown = false }
        let interruptedInput = inputID
        if showMessage { emit(.textDelta("\nNot supported here\n"), item: "opencode.unsupported") }
        // There is no generic reply endpoint for future request kinds. Interrupt
        // via the supported API and resolve locally even if no terminal SSE arrives.
        do {
            _ = try await transport.request("api/session/\(session.nativeID)/interrupt", method: "POST", body: .object([:]))
            if inputID == interruptedInput { end(.interrupted) }
        } catch { await abort() }
    }
}

private func opencodeBlocksOnUserInput(_ value: JSONValue) -> Bool {
    ["permission.asked", "form.created", "question.asked"].contains(value["type"]?.stringValue ?? "")
}

private func opencodeTokenCount(_ value: JSONValue?) -> Int? {
    guard let number = value?.doubleValue, number.isFinite, number >= 0,
          number < Double(Int.max), number.rounded(.down) == number else { return nil }
    return Int(number)
}
