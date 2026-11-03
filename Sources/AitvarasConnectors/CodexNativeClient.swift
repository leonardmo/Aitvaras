import AitvarasCore
import Foundation
import Darwin

/// A separate linked-native adapter. It never adopts ids into the isolated client,
/// starts a daemon, modifies configuration, logs in, or retries uncertain writes.
public actor CodexNativeClient {
    public let configuration: CodexNativeConnectionConfiguration
    private let nodePath: String?
    private let codexPath: String?
    private let helperPath: String?
    private let home: URL
    private let timeout: Duration
    private var process: NativeCodexProcess?
    private var reader: Task<Void, Never>?
    private var info: CodexNativeConnectionInfo?
    private var connectionID: UUID?
    private var pending: [String: Pending] = [:]
    private var listeners: [UUID: AsyncStream<CodexNativeEvent>.Continuation] = [:]
    private struct Pending {
        let continuation: CheckedContinuation<CodexJSONValue, Error>
        let timer: Task<Void, Never>
    }

    public init(configuration: CodexNativeConnectionConfiguration) {
        self.configuration = configuration
        nodePath = CodexSessionReader.findNode()
        codexPath = DelegateConnector.findAgent(kind: .codex)?.path
        helperPath = Bundle.module.url(forResource: "codex-native", withExtension: "mjs")?.path
        home = CodexSessionReader.canonicalProfileHome(explicit: configuration.codexHome,
            inherited: CodexSessionReader.environment(node: nodePath ?? "/usr/bin/node"))
        timeout = .seconds(35)
    }
    public init(config: CodexNativeConnectionConfiguration) { self.init(configuration: config) }
    init(configuration: CodexNativeConnectionConfiguration, nodePath: String?, codexPath: String?, helperPath: String?, timeout: Duration = .seconds(35)) {
        self.configuration = configuration; self.nodePath = nodePath; self.codexPath = codexPath; self.helperPath = helperPath
        home = CodexSessionReader.canonicalProfileHome(explicit: configuration.codexHome, inherited: [:]); self.timeout = timeout
    }

    /// Subscribe before connect to receive all scoped requests and notifications.
    /// Overflow disconnects the transport; native events are never silently dropped.
    public func events() -> AsyncStream<CodexNativeEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        }
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }

    public func connect() async throws -> CodexNativeConnectionInfo {
        try Task.checkCancellation()
        if let info { return info }
        guard process == nil else { throw CodexNativeError.busy }
        guard !AitvarasPaths.externalIntegrationsDisabled,
              ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] != "1" else { throw CodexNativeError.disabled }
        guard CodexSessionReader.validID(configuration.profileNamespace), home.isFileURL, home.path.hasPrefix("/"),
              !home.path.contains("\0"), home.path.utf8.count <= 4096 else { throw CodexNativeError.invalidRequest }
        guard let nodePath, let helperPath else { throw CodexNativeError.unavailable }
        var config: [String: CodexJSONValue]
        switch configuration.transport {
        case .defaultProxy:
            guard let codexPath else { throw CodexNativeError.unavailable }
            config = ["transport": "defaultProxy", "executable": .string(codexPath), "home": .string(home.path)]
        case .loopbackWebSocket(let endpoint):
            do { _ = try CodexSharedRuntimeClient.validateEndpoint(endpoint) }
            catch { throw CodexNativeError.invalidEndpoint }
            config = ["transport": "explicitLoopbackWebSocket", "endpoint": .string(endpoint)]
        }
        let running = NativeCodexProcess()
        let stream = try running.start(node: nodePath, helper: helperPath)
        let generation = UUID(); connectionID = generation; process = running
        reader = Task { [weak self] in
            do { for try await data in stream { await self?.receive(data, generation: generation) } }
            catch { await self?.closed(error as? CodexNativeError ?? .disconnected, generation: generation) }
            await self?.closed(.disconnected, generation: generation)
        }
        do {
            let raw = try await perform(["op": "connect", "configuration": .object(config)])
            let decoded = try JSONDecoder().decode(CodexNativeConnectionInfo.self, from: raw.encoded())
            guard !decoded.runtimeIdentityKnown, !decoded.desktopAttachmentVerified,
                  ["defaultProxy", "explicitLoopbackWebSocket"].contains(decoded.transport) else { throw CodexNativeError.malformed }
            info = decoded; return decoded
        } catch { close(error as? CodexNativeError ?? .unavailable); throw error }
    }

    /// Only the reviewed native methods and parameters are dispatched by the helper.
    /// Config/sandbox/tool overrides, shell, deletes, reverts and injections are absent.
    public func request(method: String, params: CodexJSONValue = .object([:])) async throws -> CodexJSONValue {
        guard info != nil else { throw CodexNativeError.disconnected }
        guard params.objectValue != nil, Self.allowedMethods.contains(method) else { throw CodexNativeError.invalidRequest }
        return try await perform(["op": "request", "method": .string(method), "params": params])
    }
    private static let allowedMethods: Set<String> = [
        "project/list", "project/read", "project/create", "project/update", "thread/list", "thread/read",
        "thread/turns/list", "thread/items/list", "thread/resume", "thread/start", "thread/metadata/update",
        "thread/name/set", "thread/archive", "thread/unarchive", "thread/unsubscribe", "model/list", "account/read",
        "account/rateLimits/read", "config/read", "turn/start", "turn/interrupt"
    ]

    public func resume(threadID: String) async throws -> CodexNativeResumeConfiguration {
        let result = try await request(method: "thread/resume", params: ["threadId": .string(threadID)])
        return try Self.effectiveConfiguration(result, expectedThreadID: threadID)
    }
    public nonisolated static func effectiveConfiguration(_ raw: CodexJSONValue, expectedThreadID: String? = nil) throws -> CodexNativeResumeConfiguration {
        guard let id = raw["thread"]?["id"]?.stringValue, CodexSessionReader.validID(id),
              expectedThreadID.map({ $0 == id }) ?? true,
              let model = raw["model"]?.stringValue, let provider = raw["modelProvider"]?.stringValue,
              let cwd = raw["cwd"]?.stringValue, cwd.hasPrefix("/"),
              let approval = raw["approvalPolicy"], let reviewer = raw["approvalsReviewer"]?.stringValue,
              let sandbox = raw["sandbox"], sandbox.objectValue != nil else { throw CodexNativeError.malformed }
        let roots = raw["runtimeWorkspaceRoots"]?.arrayValue ?? []
        guard roots.allSatisfy({ $0.stringValue?.hasPrefix("/") == true }) else { throw CodexNativeError.malformed }
        return .init(threadID: id, model: model, modelProvider: provider, cwd: cwd, approvalPolicy: approval,
                     approvalsReviewer: reviewer, sandbox: sandbox, runtimeWorkspaceRoots: roots.compactMap(\.stringValue),
                     activePermissionProfile: raw["activePermissionProfile"], raw: raw)
    }

    /// The final native idle check is not an atomic reservation: another client
    /// can start work before turn/start, whose installed API may then steer it.
    public func startTurn(threadID: String, text: String, model: String? = nil, effort: String? = nil,
                          clientUserMessageID: String? = nil) async throws -> CodexJSONValue {
        var params: [String: CodexJSONValue] = ["threadId": .string(threadID),
            "input": [["type": "text", "text": .string(text), "text_elements": []]]]
        if let model { params["model"] = .string(model) }
        if let effort { params["effort"] = .string(effort) }
        if let clientUserMessageID { params["clientUserMessageId"] = .string(clientUserMessageID) }
        return try await request(method: "turn/start", params: .object(params))
    }
    public func interrupt(threadID: String, turnID: String) async throws {
        _ = try await request(method: "turn/interrupt", params: ["threadId": .string(threadID), "turnId": .string(turnID)])
    }
    public func respond(to requestID: CodexJSONValue, threadID: String, turnID: String, result: CodexJSONValue) async throws {
        guard info != nil else { throw CodexNativeError.disconnected }
        _ = try await perform(["op": "respond", "requestID": requestID, "threadID": .string(threadID),
                               "turnID": .string(turnID), "result": result])
    }
    public func respond(to request: CodexNativeServerRequest, decision: CodexNativeApprovalDecision) async throws {
        try await respond(to: request.id, threadID: request.threadID, turnID: request.turnID,
                          result: ["decision": .string(decision.rawValue)])
    }
    public func disconnect() { close(.disconnected) }

    /// Faithful complete pagination, in native ascending order. No truncation,
    /// synthetic ids, text-only filtering, or successful partial snapshot.
    public func canonicalSnapshot(threadID: String) async throws -> CodexNativeThreadSnapshot {
        guard CodexSessionReader.validID(threadID) else { throw CodexNativeError.invalidRequest }
        let first = try await request(method: "thread/read", params: ["threadId": .string(threadID), "includeTurns": false])
        guard first["thread"]?["id"]?.stringValue == threadID else { throw CodexNativeError.malformed }
        var totalBytes = 0
        let turnValues = try await allPages(method: "thread/turns/list", threadID: threadID, extra: ["itemsView": "notLoaded"], totalBytes: &totalBytes)
        let itemValues = try await allPages(method: "thread/items/list", threadID: threadID, extra: [:], totalBytes: &totalBytes)
        var turnIDs = Set<String>(), itemIDs = Set<String>()
        var turns: [CodexNativeTurnSnapshot] = [], items: [CodexNativeItemSnapshot] = []
        for (index, raw) in turnValues.enumerated() {
            guard let id = raw["id"]?.stringValue, CodexSessionReader.validID(id), turnIDs.insert(id).inserted,
                  let status = raw["status"]?.stringValue else { throw CodexNativeError.malformed }
            turns.append(.init(id: id, status: status, order: index, raw: raw))
        }
        for (index, raw) in itemValues.enumerated() {
            guard let item = raw["item"], let id = item["id"]?.stringValue, CodexSessionReader.validID(id),
                  let turn = raw["turnId"]?.stringValue, turnIDs.contains(turn),
                  itemIDs.insert("\(turn.utf8.count):\(turn):\(id)").inserted,
                  let kind = item["type"]?.stringValue, !kind.isEmpty else { throw CodexNativeError.malformed }
            items.append(.init(id: id, turnID: turn, kind: kind, order: index, raw: raw))
        }
        let last = try await request(method: "thread/read", params: ["threadId": .string(threadID), "includeTurns": false])
        guard let raw = last["thread"], raw["id"]?.stringValue == threadID, let cwd = raw["cwd"]?.stringValue,
              let status = raw["status"]?["type"]?.stringValue else { throw CodexNativeError.malformed }
        return .init(id: threadID, name: raw["name"]?.stringValue, projectID: raw["projectId"]?.stringValue,
                     cwd: cwd, status: status, raw: raw, turns: turns, items: items, complete: true)
    }
    private func allPages(method: String, threadID: String, extra: [String: CodexJSONValue], totalBytes: inout Int) async throws -> [CodexJSONValue] {
        var cursor: String?, seen = Set<String>(), values: [CodexJSONValue] = []
        for _ in 0..<100 {
            try Task.checkCancellation()
            var params = extra
            params["threadId"] = .string(threadID); params["limit"] = 100; params["sortDirection"] = "asc"
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await request(method: method, params: .object(params))
            totalBytes += try page.encoded().count
            guard totalBytes <= 16 * 1024 * 1024, let data = page["data"]?.arrayValue, data.count <= 100,
                  values.count + data.count <= 10000 else { throw CodexNativeError.tooLarge }
            guard data.allSatisfy({ $0.objectValue != nil }) else { throw CodexNativeError.malformed }
            values.append(contentsOf: data)
            guard let next = page["nextCursor"], next != .null else { return values }
            guard let nextCursor = next.stringValue, !nextCursor.isEmpty, nextCursor.utf8.count <= 16384,
                  seen.insert(nextCursor).inserted else { throw CodexNativeError.malformed }
            cursor = nextCursor
        }
        throw CodexNativeError.tooLarge
    }

    private func perform(_ fields: [String: CodexJSONValue]) async throws -> CodexJSONValue {
        try Task.checkCancellation()
        guard let process, let generation = connectionID else { throw CodexNativeError.disconnected }
        guard pending.count < 64 else { throw CodexNativeError.busy }
        let id = UUID().uuidString
        var command = fields; command["id"] = .string(id)
        let data = try CodexJSONValue.object(command).encoded()
        guard data.count <= 2 * 1024 * 1024 else { throw CodexNativeError.tooLarge }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout); await self?.expire(id) } catch {}
                }
                pending[id] = Pending(continuation: continuation, timer: timer)
                process.send(data) { [weak self] success in
                    if !success { Task { await self?.closed(.disconnected, generation: generation) } }
                }
            }
        } onCancel: { [weak self] in Task { await self?.cancelOperation(id) } }
    }
    private func cancelOperation(_ id: String) {
        guard let operation = pending.removeValue(forKey: id) else { return }
        operation.timer.cancel(); operation.continuation.resume(throwing: CancellationError())
        // Cancellation closes this client only; it never interrupts the native
        // turn or automatically assumes that an in-flight native write failed.
        close(.disconnected)
    }
    private func expire(_ id: String) { if pending[id] != nil { close(.timeout) } }
    private func receive(_ data: Data, generation: UUID) {
        guard connectionID == generation else { return }
        do {
            let frame = try JSONDecoder().decode(CodexJSONValue.self, from: data)
            guard let kind = frame["kind"]?.stringValue else { throw CodexNativeError.malformed }
            switch kind {
            case "result", "error":
                guard let id = frame["id"]?.stringValue, let operation = pending.removeValue(forKey: id) else { throw CodexNativeError.malformed }
                operation.timer.cancel()
                if kind == "error" { operation.continuation.resume(throwing: CodexNativeError(rawValue: frame["code"]?.stringValue ?? "") ?? .unavailable) }
                else if let result = frame["result"] { operation.continuation.resume(returning: result) }
                else { operation.continuation.resume(throwing: CodexNativeError.malformed); throw CodexNativeError.malformed }
            case "notification":
                guard let method = frame["method"]?.stringValue, let params = frame["params"] else { throw CodexNativeError.malformed }
                emit(.notification(method: method, params: params))
            case "serverRequest":
                guard let id = frame["id"], id.stringValue != nil || id.intValue != nil,
                      let method = frame["method"]?.stringValue, let params = frame["params"],
                      let thread = params["threadId"]?.stringValue, let turn = params["turnId"]?.stringValue else { throw CodexNativeError.malformed }
                emit(.serverRequest(.init(id: id, method: method, threadID: thread, turnID: turn,
                                          itemID: params["itemId"]?.stringValue, params: params)))
            case "disconnected": close(CodexNativeError(rawValue: frame["code"]?.stringValue ?? "") ?? .disconnected)
            default: throw CodexNativeError.malformed
            }
        } catch { close(error as? CodexNativeError ?? .malformed) }
    }
    private func emit(_ event: CodexNativeEvent) {
        var overflow = false
        for listener in listeners.values { if case .dropped = listener.yield(event) { overflow = true } }
        if overflow { close(.tooLarge) }
    }
    private func closed(_ error: CodexNativeError, generation: UUID) {
        if connectionID == generation { close(error) }
    }
    private func close(_ error: CodexNativeError) {
        let wasConnected = process != nil
        info = nil; connectionID = nil; let old = process; process = nil; reader?.cancel(); reader = nil
        for operation in pending.values { operation.timer.cancel(); operation.continuation.resume(throwing: error) }
        pending.removeAll(); old?.stop()
        if wasConnected {
            for listener in listeners.values { _ = listener.yield(.disconnected); listener.finish() }
            listeners.removeAll()
        }
    }
}

/// Only helper/proxy subprocesses created by this instance are owned. Never a
/// native shared server or desktop process. Pipe I/O and termination are bounded.
private final class NativeCodexProcess: @unchecked Sendable {
    private let lock = NSLock(), process = Process(), input = Pipe(), output = Pipe()
    private let writes = DispatchQueue(label: "aitvaras.codex.native-write")
    private var stopping = false, launched = false
    private var proxyGroups = Set<Int32>()
    func start(node: String, helper: String) throws -> AsyncThrowingStream<Data, Error> {
        process.executableURL = URL(fileURLWithPath: node); process.arguments = [helper]
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "NO_COLOR": "1"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); lock.withLock { launched = true }
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation in
            DispatchQueue(label: "aitvaras.codex.native-read").async { [self] in
                defer { try? output.fileHandleForReading.close() }
                do {
                    var buffer = Data(), scratch = [UInt8](repeating: 0, count: 16384), total = 0, scanned = 0
                    while true {
                        let count = scratch.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
                        if count < 0 { if errno == EINTR { continue }; throw CodexNativeError.disconnected }
                        if count == 0 { break }
                        total += count
                        scratch.withUnsafeBufferPointer { bytes in buffer.append(bytes.baseAddress!, count: count) }
                        guard total <= 64 * 1024 * 1024, buffer.count <= 4 * 1024 * 1024 else { throw CodexNativeError.tooLarge }
                        while true {
                            let searchStart = buffer.index(buffer.startIndex, offsetBy: scanned)
                            guard let end = buffer[searchStart...].firstIndex(of: 10) else { scanned = buffer.count; break }
                            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                            scanned = 0
                            let frame = try JSONDecoder().decode(CodexJSONValue.self, from: line)
                            if let kind = frame["kind"]?.stringValue, ["proxyProcess", "proxyProcessEnded"].contains(kind) {
                                guard let pid = frame["pid"]?.intValue, pid > 1, pid <= Int(Int32.max) else { throw CodexNativeError.malformed }
                                lock.withLock { if kind == "proxyProcess" { _ = proxyGroups.insert(Int32(pid)) } else { _ = proxyGroups.remove(Int32(pid)) } }
                                continue
                            }
                            if case .dropped = continuation.yield(line) { throw CodexNativeError.tooLarge }
                        }
                    }
                    guard buffer.isEmpty else { throw CodexNativeError.malformed }
                    continuation.finish()
                } catch { continuation.finish(throwing: error); stop() }
            }
        }
    }
    func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
        writes.async { [self] in
            guard !lock.withLock({ stopping }) else { completion(false); return }
            do { var line = data; line.append(10); try input.fileHandleForWriting.write(contentsOf: line); completion(true) }
            catch { completion(false) }
        }
    }
    func stop() {
        let shouldStop = lock.withLock { if stopping { return false }; stopping = true; return true }
        guard shouldStop else { return }
        if lock.withLock({ launched }) && process.isRunning { process.terminate() }
        // Give the helper its own bounded proxy cleanup first, then clean only
        // recorded child process groups if it failed or was interrupted.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
            let groups = lock.withLock { proxyGroups }
            for group in groups { _ = Darwin.kill(-group, SIGKILL) }
            if lock.withLock({ launched }) && process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            try? input.fileHandleForWriting.close()
        }
    }
}
