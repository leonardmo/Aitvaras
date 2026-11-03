import Foundation

/// A profile-qualified native identity. The namespace is opaque, never an account ID or credential.
public struct NativeProjectIdentity: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var provider: NativeSessionProvider
    public var hostID: String
    public var profileNamespace: String
    public var externalID: String
    public var id: Self { self }

    public init(provider: NativeSessionProvider, hostID: String = "local", profileNamespace: String,
                externalID: String) {
        self.provider = provider; self.hostID = hostID
        self.profileNamespace = profileNamespace; self.externalID = externalID
    }
}

/// Native root order is preserved. No root is implicitly the execution working directory.
public struct NativeProjectRoot: Codable, Sendable, Equatable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

/// Observed native metadata, not an execution or filesystem access grant.
public struct NativeProjectSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var identity: NativeProjectIdentity
    public var name: String
    public var roots: [NativeProjectRoot]
    public var createdAt: Date?
    public var updatedAt: Date?
    public var position: Int64?
    public var recencyAt: Date?
    public var metadata: [String: String]
    public var id: NativeProjectIdentity { identity }

    public init(identity: NativeProjectIdentity, name: String, roots: [NativeProjectRoot],
                createdAt: Date? = nil, updatedAt: Date? = nil, position: Int64? = nil,
                recencyAt: Date? = nil, metadata: [String: String] = [:]) {
        self.identity = identity; self.name = name; self.roots = roots
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.position = position
        self.recencyAt = recencyAt; self.metadata = metadata
    }
}

public struct NativeProjectPage: Codable, Sendable, Equatable {
    public var projects: [NativeProjectSnapshot]
    public var nextCursor: String?
    public var coverage: String
    public init(projects: [NativeProjectSnapshot], nextCursor: String? = nil, coverage: String) {
        self.projects = projects; self.nextCursor = nextCursor; self.coverage = coverage
    }
}

public struct NativeProjectCapability: Codable, Sendable, Equatable {
    public var provider: NativeSessionProvider
    public var state: NativeSessionCapability.State
    public var profileNamespace: String
    public var version: String?
    /// Only methods actually verified by this check; an empty project list cannot verify project/read.
    public var verifiedMethods: [String]
    public var detail: String
    public init(provider: NativeSessionProvider, state: NativeSessionCapability.State,
                profileNamespace: String, version: String? = nil,
                verifiedMethods: [String] = [], detail: String) {
        self.provider = provider; self.state = state; self.profileNamespace = profileNamespace
        self.version = version; self.verifiedMethods = verifiedMethods; self.detail = detail
    }
}

/// Discovery is independent of native continuation; these methods never resume or mutate a project/thread.
public protocol NativeProjectReader: Sendable {
    var profileNamespace: String { get }
    func projectCapabilities() async -> NativeProjectCapability
    func listProjects(cursor: String?) async throws -> NativeProjectPage
    func readProject(id: String) async throws -> NativeProjectSnapshot
}
