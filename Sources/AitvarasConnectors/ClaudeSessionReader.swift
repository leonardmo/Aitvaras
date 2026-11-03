import Foundation
import AitvarasCore

/// Optional, pull-only local-history adapter. The helper calls only the official
/// SDK's listSessions, getSessionInfo, and getSessionMessages read APIs.
public struct ClaudeSessionReader: NativeSessionReader {
    public let provider: NativeSessionProvider = .claude
    public static let sdkVersion = "0.3.306"
    static let maximumOffset = 1_000_000
    static let pageSize = 50
    static let maximumResponseBytes = 900_000

    public static var sdkDirectory: URL {
        AitvarasPaths.stateDirectory.appendingPathComponent("NativeAdapters/claude-sdk", isDirectory: true)
    }

    /// Presence only; use capabilities() to validate version and read APIs.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: sdkDirectory.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json").path)
    }

    typealias Transport = @Sendable (Data) async throws -> Data
    private let transport: Transport?

    public init() { transport = nil }
    init(transport: @escaping Transport) { self.transport = transport }

    public enum ReaderError: String, Error, LocalizedError, Sendable {
        case missingRuntime, missingSDK, unsupported, invalidRequest, unsupportedArchive
        case notFound, malformedData, pageOverflow, outputTooLarge, readFailed, installFailed, disabled

        public var errorDescription: String? {
            switch self {
            case .missingRuntime: "Node.js or npm is unavailable. Install Node.js 18 or newer to use local Claude Code history."
            case .missingSDK: "The optional Claude history SDK is not installed for this Aitvaras profile."
            case .unsupported: "The Claude history SDK version or read-only API is unsupported. Reinstall the pinned SDK."
            case .invalidRequest: "The Claude history request or pagination cursor is invalid."
            case .unsupportedArchive: "The official Claude SDK does not expose archive status or an archived-only filter."
            case .notFound: "The local Claude Code session is unavailable or is not exposed by the official SDK."
            case .malformedData: "Claude history returned an invalid response; no transcript was imported."
            case .pageOverflow: "Claude history exceeded the supported pagination range."
            case .outputTooLarge: "This Claude history page is too large to read safely; no transcript was imported."
            case .readFailed: "The local Claude history read failed. No provider content is included in this error."
            case .installFailed: "The optional Claude history SDK could not be installed. No provider content was sent."
            case .disabled: "External integrations are disabled for this Aitvaras profile."
            }
        }
    }

    public func capabilities() async -> NativeSessionCapability {
        do {
            let result: NativeSessionCapability = try await request(.init(operation: "capabilities"))
            guard result.provider == .claude, result.state == .ready, result.version == Self.sdkVersion else {
                throw ReaderError.unsupported
            }
            return result
        } catch {
            let reason = error as? ReaderError ?? .readFailed
            let state: NativeSessionCapability.State
            switch reason {
            case .missingRuntime: state = .missingRuntime
            case .missingSDK: state = .missingSDK
            case .unsupported: state = .unsupported
            default: state = .unavailable
            }
            return .init(provider: .claude, state: state, detail: reason.localizedDescription)
        }
    }

    public func listSessions(cursor: String?, archived: Bool) async throws -> NativeSessionPage {
        guard !archived else { throw ReaderError.unsupportedArchive }
        let offset = try Self.offset(cursor)
        let result: NativeSessionPage = try await request(.init(operation: "list", offset: offset, archived: false))
        guard result.sessions.count <= Self.pageSize,
              Set(result.sessions.map(\.externalID)).count == result.sessions.count,
              result.sessions.allSatisfy(Self.validSession) else { throw ReaderError.malformedData }
        try Self.validateCursor(result.nextCursor, after: offset)
        return result
    }

    public func readSession(id: String, directory: String?, cursor: String?) async throws -> NativeTranscriptPage {
        guard UUID(uuidString: id) != nil,
              directory == nil || (directory!.hasPrefix("/") && !directory!.contains("\0")) else {
            throw ReaderError.invalidRequest
        }
        let offset = try Self.offset(cursor)
        let result: NativeTranscriptPage = try await request(.init(operation: "read", id: id, directory: directory, offset: offset))
        guard Self.validSession(result.session), result.session.externalID == id,
              result.messages.count <= Self.pageSize,
              Set(result.messages.map(\.externalID)).count == result.messages.count,
              result.messages.allSatisfy({ UUID(uuidString: $0.externalID) != nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ReaderError.malformedData
        }
        try Self.validateCursor(result.nextCursor, after: offset)
        return result
    }

    static func offset(_ cursor: String?) throws -> Int {
        guard let cursor else { return 0 }
        guard !cursor.isEmpty, cursor.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let offset = Int(cursor), offset >= 0, offset <= maximumOffset,
              String(offset) == cursor else { throw ReaderError.invalidRequest }
        return offset
    }

    private static func validSession(_ session: NativeSessionSummary) -> Bool {
        session.provider == .claude && session.hostID == "local"
            && UUID(uuidString: session.externalID) != nil
            && session.archived == nil && session.parentExternalID == nil
            && session.updatedAt?.timeIntervalSince1970.isFinite == true
    }

    private static func validateCursor(_ cursor: String?, after offset: Int) throws {
        guard let cursor else { return }
        let next: Int
        do { next = try Self.offset(cursor) } catch { throw ReaderError.malformedData }
        guard next == offset + pageSize else { throw ReaderError.malformedData }
    }

    private struct Request: Encodable {
        let operation: String
        var sdkDirectory: String = ClaudeSessionReader.sdkDirectory.path
        var id: String?
        var directory: String?
        var offset: Int?
        var archived: Bool?
    }

    private struct Envelope<Value: Decodable>: Decodable {
        let ok: Bool
        let result: Value?
        let error: String?
    }

    private func request<Value: Decodable>(_ request: Request) async throws -> Value {
        let input = try JSONEncoder().encode(request)
        let output: Data
        if let transport {
            output = try await transport(input)
        } else {
            guard !AitvarasPaths.externalIntegrationsDisabled else { throw ReaderError.disabled }
            guard let node = Self.findExecutable("node") else { throw ReaderError.missingRuntime }
            guard Self.isInstalled else {
                throw ReaderError.missingSDK
            }
            guard let helper = Bundle.module.url(forResource: "claude-history", withExtension: "mjs") else { throw ReaderError.unsupported }
            do {
                let result = try await ProcessRunner.run(
                    executable: node, arguments: [helper.path], currentDirectory: nil,
                    timeout: 30, environment: Self.environment(node: node), standardInput: input)
                guard !result.timedOut, result.exitCode == 0 else { throw ReaderError.readFailed }
                output = Data(result.stdout.utf8)
            } catch is CancellationError { throw CancellationError() }
            catch let error as ReaderError { throw error }
            catch { throw ReaderError.readFailed }
        }
        return try Self.decode(output)
    }

    static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        guard data.count <= maximumResponseBytes else { throw ReaderError.outputTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope: Envelope<Value>
        do { envelope = try decoder.decode(Envelope<Value>.self, from: data) }
        catch { throw ReaderError.malformedData }
        guard envelope.ok else { throw ReaderError(rawValue: envelope.error ?? "") ?? .readFailed }
        guard envelope.error == nil, let result = envelope.result else { throw ReaderError.malformedData }
        return result
    }

    /// Must be called only after an explicit user installation action. No read,
    /// capability check, app launch, or timer invokes this method.
    @discardableResult
    public static func installSDK() async throws -> NativeSessionCapability {
        guard !AitvarasPaths.externalIntegrationsDisabled else { throw ReaderError.disabled }
        guard let node = findExecutable("node"), let npm = findExecutable("npm") else { throw ReaderError.missingRuntime }
        let directory = sdkDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (resource, target) in [("claude-sdk-package", "package.json"), ("claude-sdk-package-lock", "package-lock.json")] {
                guard let source = Bundle.module.url(forResource: resource, withExtension: "json") else { throw ReaderError.unsupported }
                try Data(contentsOf: source).write(to: directory.appendingPathComponent(target), options: .atomic)
            }
            let home = directory.appendingPathComponent("install-home", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let emptyConfig = home.appendingPathComponent("npmrc")
            try Data().write(to: emptyConfig, options: .atomic)
            var environment = Self.environment(node: node, home: home.path)
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
            environment["NPM_CONFIG_USERCONFIG"] = emptyConfig.path
            environment["NPM_CONFIG_GLOBALCONFIG"] = "/dev/null"
            environment["NPM_CONFIG_CACHE"] = directory.appendingPathComponent("npm-cache", isDirectory: true).path
            let result = try await ProcessRunner.run(
                executable: npm,
                arguments: ["ci", "--ignore-scripts", "--omit=optional", "--no-audit", "--no-fund", "--registry=https://registry.npmjs.org"],
                currentDirectory: directory.path, timeout: 180, environment: environment)
            guard !result.timedOut, result.exitCode == 0 else { throw ReaderError.installFailed }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ReaderError { throw error }
        catch { throw ReaderError.installFailed }
        let capability = await ClaudeSessionReader().capabilities()
        guard capability.state == .ready else { throw ReaderError.unsupported }
        return capability
    }

    static func findExecutable(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let standard = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.volta/bin", "\(home)/.asdf/shims", "/usr/bin", "/bin"]
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return (standard + inherited).map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Explicit allowlist excludes auth tokens, NODE_OPTIONS, shell setup,
    /// provider endpoints and npm credentials from the helper/installer.
    static func environment(node: String, home: String? = nil) -> [String: String] {
        var result = [
            "HOME": home ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "\(URL(fileURLWithPath: node).deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "LANG": "en_US.UTF-8", "NO_COLOR": "1"
        ]
        if let directory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], directory.hasPrefix("/"), !directory.contains("\0") {
            result["CLAUDE_CONFIG_DIR"] = directory
        }
        return result
    }
}
