import Foundation

/// A native external-directory approval can authorize one exact invocation.
struct OpencodeShellApproval: Sendable {
    let id = UUID()
    let sessionID: String
    let command: String
    let directory: String
    let externalDirectories: [URL]

    init?(sessionID: String, command: String, workdir: String?, project: URL, resources: [JSONValue]) {
        guard !command.isEmpty, command.utf8.count <= 64 * 1024, !resources.isEmpty, resources.count <= 32 else { return nil }
        let base = workdir.map {
            URL(fileURLWithPath: $0.hasPrefix("/") ? $0 : (project.path as NSString).appendingPathComponent($0))
        } ?? project
        let directory = OpencodeConfiguration.realPath(base.standardizedFileURL.path)
        let roots = resources.compactMap { resource -> URL? in
            guard let raw = resource.stringValue, raw.hasPrefix("/"), raw.hasSuffix("/*") else { return nil }
            let path = String(raw.dropLast(2))
            guard !path.isEmpty, !path.contains("\0"), !path.contains("*") else { return nil }
            return URL(fileURLWithPath: OpencodeConfiguration.realPath(path), isDirectory: true)
        }
        guard roots.count == resources.count, roots.allSatisfy({ $0.path != "/" }) else { return nil }
        self.sessionID = sessionID
        self.command = command
        self.directory = directory
        self.externalDirectories = roots
    }
}

actor OpencodeShellBridge {
    private struct Permit: Sendable {
        let approval: OpencodeShellApproval
        let expires: ContinuousClock.Instant
    }

    private let configuration: OpencodeConfiguration
    private let projects: [URL]
    private let environment: [String: String]
    private var permits: [UUID: Permit] = [:]
    private var active: [UUID: (sessionID: String, task: Task<JSONValue?, Never>)] = [:]
    private var closed = false

    init(configuration: OpencodeConfiguration, projects: [URL], environment: [String: String]) {
        self.configuration = configuration
        self.projects = projects
        self.environment = environment
    }

    func authorize(_ approval: OpencodeShellApproval) throws {
        let now = ContinuousClock.now
        permits = permits.filter { $0.value.expires > now }
        guard !closed, permits.count < 64 else { throw AgentFailure.invalidTransition }
        permits[approval.id] = .init(approval: approval, expires: now.advanced(by: .seconds(60)))
    }

    func revoke(approvalID: UUID) {
        permits[approvalID] = nil
        active[approvalID]?.task.cancel()
    }

    func revoke(sessionID: String) {
        permits = permits.filter { $0.value.approval.sessionID != sessionID }
        for entry in active.values where entry.sessionID == sessionID { entry.task.cancel() }
    }

    func close() {
        closed = true
        permits.removeAll()
        for entry in active.values { entry.task.cancel() }
    }

    func execute(_ request: JSONValue) async -> JSONValue? {
        guard !closed, let sessionID = request["session"]?.stringValue,
              let command = request["command"]?.stringValue, let directory = request["directory"]?.stringValue else { return nil }
        let now = ContinuousClock.now
        permits = permits.filter { $0.value.expires > now }
        guard let match = permits.first(where: {
            $0.value.approval.sessionID == sessionID && $0.value.approval.command == command
                && $0.value.approval.directory == directory
        }) else { return .object(["contained": .bool(true)]) }
        permits[match.key] = nil
        let approval = match.value.approval
        let task = Task { [configuration, projects, environment] () -> JSONValue? in
            guard OpencodeConfiguration.realPath(directory) == directory,
                  approval.externalDirectories.allSatisfy({ OpencodeConfiguration.realPath($0.path) == $0.path })
            else { return nil }
            do {
                let policy = try configuration.sandbox(projects: projects, unrestrictedWrites: false, shellSocket: nil,
                                                       approvedExternalRoots: approval.externalDirectories.map(\.path))
                let result = try await OneShotProcess.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                    arguments: ["-p", policy, "/bin/zsh", "-c", command],
                    currentDirectory: URL(fileURLWithPath: directory, isDirectory: true), environment: environment,
                    timeout: .seconds(120), stdoutTailBytes: 64 * 1024)
                return .object(["stdout": .string(Data(result.stdout.utf8).base64EncodedString()),
                                "stderr": .string(Data(result.stderr.utf8.suffix(8 * 1024)).base64EncodedString()),
                                "exitCode": .number(Double(result.exitCode))])
            } catch { return nil }
        }
        active[match.key] = (sessionID, task)
        defer { active[match.key] = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }
}
