import AitvarasCore
import CryptoKit
import Foundation

/// Local, read-only app-server history. This never resumes or executes a thread.
public struct CodexSessionReader: NativeSessionReader, NativeProjectReader {
    public let provider: NativeSessionProvider = .codex
    private let nodePath: String?
    private let codexPath: String?
    private let helperPath: String?
    private let timeout: TimeInterval
    public let profileNamespace: String
    private let processEnvironment: [String: String]

    public init(profileNamespace: String? = nil, codexHome: URL? = nil) {
        self.init(nodePath: Self.findNode(),
                  codexPath: DelegateConnector.findAgent(kind: .codex)?.path,
                  helperPath: Bundle.module.url(forResource: "codex-history", withExtension: "mjs")?.path,
                  profileNamespace: profileNamespace, codexHome: codexHome)
    }

    init(nodePath: String?, codexPath: String?, helperPath: String?, timeout: TimeInterval = 20,
         profileNamespace: String? = nil, codexHome: URL? = nil) {
        self.nodePath = nodePath; self.codexPath = codexPath
        self.helperPath = helperPath; self.timeout = timeout
        var environment = Self.environment(node: nodePath ?? "/usr/bin/node")
        let effectiveHome = Self.canonicalProfileHome(explicit: codexHome, inherited: environment)
        // Freeze routing and identity together; a later environment change cannot retarget this reader.
        environment["CODEX_HOME"] = effectiveHome.path
        self.processEnvironment = environment
        self.profileNamespace = profileNamespace ?? Self.namespace(for: effectiveHome)
    }

    public func projectCapabilities() async -> NativeProjectCapability {
        let base = await runtimeCapability()
        if let base { return .init(provider: .codex, state: base.state,
            profileNamespace: profileNamespace, detail: base.detail) }
        do { return try await perform(Request(operation: "projectCapabilities", profileNamespace: profileNamespace)) }
        catch let error as HistoryError {
            return .init(provider: .codex, state: error == .unsupported ? .unsupported : .unavailable,
                         profileNamespace: profileNamespace, detail: error.localizedDescription)
        } catch {
            return .init(provider: .codex, state: .unavailable, profileNamespace: profileNamespace,
                         detail: "Codex project discovery did not complete. No native project was changed.")
        }
    }

    public func listProjects(cursor: String? = nil) async throws -> NativeProjectPage {
        try Self.validate(cursor: cursor)
        return try await perform(Request(operation: "listProjects", cursor: cursor, profileNamespace: profileNamespace))
    }

    public func readProject(id: String) async throws -> NativeProjectSnapshot {
        guard Self.validID(id) else { throw HistoryError.invalidRequest }
        return try await perform(Request(operation: "readProject", id: id, profileNamespace: profileNamespace))
    }

    private func runtimeCapability() async -> NativeSessionCapability? {
        if AitvarasPaths.externalIntegrationsDisabled {
            return .init(provider: .codex, state: .unavailable, detail: HistoryError.disabled.localizedDescription)
        }
        if nodePath == nil { return .init(provider: .codex, state: .missingRuntime,
            detail: "Node.js was not found in the supported local runtime locations.") }
        if codexPath == nil { return .init(provider: .codex, state: .missingSDK,
            detail: "Codex CLI was not found in the supported local install locations.") }
        return nil
    }

    public func capabilities() async -> NativeSessionCapability {
        guard !AitvarasPaths.externalIntegrationsDisabled else {
            return .init(provider: .codex, state: .unavailable, detail: HistoryError.disabled.localizedDescription)
        }
        guard nodePath != nil else {
            return .init(provider: .codex, state: .missingRuntime,
                         detail: "Node.js was not found in the supported local runtime locations.")
        }
        guard codexPath != nil else {
            return .init(provider: .codex, state: .missingSDK,
                         detail: "Codex CLI was not found in the supported local install locations.")
        }
        do { return try await perform(Request(operation: "capabilities")) }
        catch let error as HistoryError {
            return .init(provider: .codex, state: error == .unsupported ? .unsupported : .unavailable,
                         detail: error.localizedDescription)
        } catch {
            return .init(provider: .codex, state: .unavailable, detail: "Codex history capability check did not complete.")
        }
    }

    public func listSessions(cursor: String?, archived: Bool) async throws -> NativeSessionPage {
        try Self.validate(cursor: cursor)
        return try await perform(Request(operation: "list", cursor: cursor, archived: archived))
    }

    public func readSession(id: String, directory: String?, cursor: String?) async throws -> NativeTranscriptPage {
        guard Self.validID(id) else { throw HistoryError.invalidRequest }
        try Self.validate(cursor: cursor)
        // Directory is metadata only, never a process working directory or routing authority.
        return try await perform(Request(operation: "read", id: id, cursor: cursor))
    }

    enum HistoryError: Error, LocalizedError, Equatable {
        case invalidRequest, missingRuntime, unavailable, unsupported, timeout, malformed, tooLarge, disabled
        var errorDescription: String? {
            switch self {
            case .invalidRequest: "The Codex history/project identifier, profile namespace or continuation cursor is invalid."
            case .missingRuntime: "The local Node.js or Codex runtime is unavailable."
            case .unavailable: "Codex history could not be read. No native session was changed."
            case .unsupported: "This Codex CLI does not support the required read-only history methods."
            case .timeout: "The Codex history request timed out."
            case .malformed: "Codex returned an unsupported or malformed history response."
            case .tooLarge: "This Codex history page exceeds the safe size limit; it was not imported."
            case .disabled: "External integrations are disabled for this Aitvaras profile."
            }
        }
    }

    private struct Request: Encodable {
        var operation: String
        var id: String? = nil
        var cursor: String? = nil
        var archived: Bool = false
        var executable: String? = nil
        var profileNamespace: String? = nil
    }

    private struct Failure: Decodable { var error: String }

    private func perform<Result: Decodable>(_ input: Request) async throws -> Result {
        try Task.checkCancellation()
        if let namespace = input.profileNamespace, !Self.validID(namespace) { throw HistoryError.invalidRequest }
        guard !AitvarasPaths.externalIntegrationsDisabled else { throw HistoryError.disabled }
        guard let nodePath, let codexPath, let helperPath else { throw HistoryError.missingRuntime }
        var request = input
        request.executable = codexPath
        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(executable: nodePath, arguments: [helperPath],
                currentDirectory: nil, timeout: timeout,
                environment: processEnvironment,
                standardInput: JSONEncoder().encode(request))
        } catch is CancellationError { throw CancellationError() }
        catch { throw HistoryError.unavailable }
        guard !output.timedOut else { throw HistoryError.timeout }
        let data = Data(output.stdout.utf8)
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            switch failure.error {
            case "invalidRequest": throw HistoryError.invalidRequest
            case "unsupported": throw HistoryError.unsupported
            case "tooLarge": throw HistoryError.tooLarge
            case "timeout": throw HistoryError.timeout
            case "malformed": throw HistoryError.malformed
            default: throw HistoryError.unavailable
            }
        }
        guard output.exitCode == 0 else { throw HistoryError.unavailable }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(Result.self, from: data)
        } catch { throw HistoryError.malformed }
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}\\z", options: .regularExpression) != nil
    }

    private static func validate(cursor: String?) throws {
        if let cursor {
            guard !cursor.isEmpty, cursor.utf8.count <= 16_384,
                  cursor.range(of: "^[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil else {
                throw HistoryError.invalidRequest
            }
        }
    }

    static func findNode() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Fixed trusted install locations only; no shell, PATH lookup, or package installation.
        return ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
                "\(home)/.local/bin/node", "\(home)/.volta/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func canonicalProfileHome(explicit: URL?, inherited: [String: String]) -> URL {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let home = explicit ?? inherited["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fallback
        return home.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func namespace(for canonicalHome: URL) -> String {
        "profile-" + SHA256.hash(data: Data(canonicalHome.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Native history discovery needs a home directory, not auth tokens,
    /// NODE_OPTIONS, shell configuration, or inherited provider endpoints.
    static func environment(node: String,
                            inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "\(URL(fileURLWithPath: node).deletingLastPathComponent().path):/usr/bin:/bin",
            "LANG": "en_US.UTF-8", "NO_COLOR": "1"
        ]
        if let home = inherited["CODEX_HOME"], home.hasPrefix("/"), home.utf8.count <= 4_096,
           !home.contains("\0") {
            result["CODEX_HOME"] = home
        }
        return result
    }
}
