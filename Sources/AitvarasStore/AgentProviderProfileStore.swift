import Foundation
import GRDB
import AitvarasCore
import AitvarasAgents

extension AgentProviderProfile: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentProviderProfile" }
}

extension Stores {
    public func providerProfiles(provider: AgentProvider? = nil, includeDeleted: Bool = false) throws -> [AgentProviderProfile] {
        try db.queue.read { db in
            var query = AgentProviderProfile.filter(includeDeleted ? SQL("1") : SQL("isDeleted = 0"))
            if let provider { query = query.filter(Column("kind") == provider.rawValue) }
            return try query.order(Column("sortOrder"), Column("createdAt"), Column("id")).fetchAll(db)
        }
    }

    public func providerProfile(_ choice: AgentProviderChoice, includeDeleted: Bool = false) throws -> AgentProviderProfile? {
        try db.queue.read { try Self.providerProfile(choice, includeDeleted: includeDeleted, in: $0) }
    }

    static func providerProfile(_ choice: AgentProviderChoice, includeDeleted: Bool = false, in db: Database) throws -> AgentProviderProfile? {
        let id = choice.profile == "default" ? AgentProviderProfile.defaultID(for: choice.provider) : UUID(uuidString: choice.profile)
        guard let id, let row = try AgentProviderProfile.fetchOne(db, key: id), row.kind == choice.provider,
              includeDeleted || !row.isDeleted else { return nil }
        return row
    }

    public func saveProviderProfile(_ profile: AgentProviderProfile) throws {
        let name = try Self.validProfileName(profile.name)
        let isDefault = profile.id == AgentProviderProfile.defaultID(for: profile.kind)
        let efforts = profile.kind == .codex ? ["minimal", "low", "medium", "high", "xhigh"] : ["low", "medium", "high", "max"]
        guard !profile.badge.isEmpty, profile.badge.count <= 4,
              ["orange", "blue", "green", "purple", "red"].contains(profile.colour),
              !profile.defaultModel.isEmpty, profile.defaultModel.count <= 256, !profile.defaultModel.contains("\0"),
              efforts.contains(profile.defaultEffort),
              (profile.kind != .local || isDefault),
              (isDefault ? profile.configDirectory == nil
                : profile.configDirectory?.hasPrefix("/") == true && profile.configDirectory?.contains("\0") == false) else {
            throw AgentStoreError.invalidValue
        }
        try profileAction("Save provider profile", profileID: profile.id) {
            try db.queue.write { db in
                if let old = try AgentProviderProfile.fetchOne(db, key: profile.id) {
                    guard old.kind == profile.kind, old.configDirectory == profile.configDirectory,
                          !old.isDeleted, !profile.isDeleted else { throw AgentStoreError.identityConflict }
                }
                var value = profile; value.name = name
                value.createdAt = try AgentProviderProfile.fetchOne(db, key: profile.id)?.createdAt ?? profile.createdAt
                try value.save(db)
            }
        }
    }

    @discardableResult public func createProviderProfile(kind: AgentProvider, name: String, stateDirectory: URL,
                                                         claudeDefaultDirectory: URL, useExistingCLI: Bool = false,
                                                         defaultModel: String? = nil, defaultEffort: String? = nil) throws -> AgentProviderProfile {
        let name = try Self.validProfileName(name)
        let efforts = kind == .codex ? ["minimal", "low", "medium", "high", "xhigh"] : ["low", "medium", "high", "max"]
        if let defaultModel {
            guard !defaultModel.isEmpty, defaultModel.count <= 256, !defaultModel.contains("\0") else { throw AgentStoreError.invalidValue }
        }
        if let defaultEffort, !efforts.contains(defaultEffort) { throw AgentStoreError.invalidValue }
        let usesDefault = kind == .local || useExistingCLI
        let id = usesDefault ? AgentProviderProfile.defaultID(for: kind) : UUID()
        return try profileAction("Add provider profile", profileID: id) {
            let directory: String?
            if usesDefault { directory = nil }
            else if kind == .claude {
                directory = try ClaudeProfileDirectory.create(stateDirectory: stateDirectory, defaultDirectory: claudeDefaultDirectory, id: id).path
            } else {
                directory = try ClaudeProfileDirectory.createCodexHome(stateDirectory: stateDirectory, id: id).path
            }
            return try db.queue.write { db in
                let old = try AgentProviderProfile.fetchOne(db, key: id)
                guard old == nil || old?.isDeleted == true else { throw AgentStoreError.identityConflict }
                let profiles = try AgentProviderProfile.filter(Column("isDeleted") == false).fetchAll(db)
                let colour = switch kind { case .claude: "orange"; case .codex: "blue"; case .local: "green" }
                var value = old ?? AgentProviderProfile(id: id, name: name, kind: kind, badge: String(name.prefix(2)),
                    colour: colour, configDirectory: directory)
                value.name = name
                if let defaultModel { value.defaultModel = defaultModel }
                if let defaultEffort { value.defaultEffort = defaultEffort }
                value.isDeleted = false
                value.sortOrder = (profiles.map(\.sortOrder).max() ?? -1) + 1
                try value.save(db)
                return value
            }
        }
    }

    public func authorizeProviderSignIn(_ choice: AgentProviderChoice) throws {
        guard choice.provider != .local, let profile = try providerProfile(choice) else { throw AgentStoreError.invalidValue }
        try profileAction("Sign in to provider profile", profileID: profile.id) {}
    }

    public func deleteProviderProfile(id: UUID) throws {
        try profileAction("Remove provider profile", profileID: id) {
            try db.queue.write { db in
                guard var profile = try AgentProviderProfile.fetchOne(db, key: id), !profile.isDeleted else { throw AgentStoreError.invalidValue }
                profile.isDeleted = true
                try profile.update(db)
            }
        }
        // Keep native files and chat history for removed accounts.
    }

    public func reorderProviderProfiles(ids: [UUID], provider: AgentProvider? = nil) throws {
        guard Set(ids).count == ids.count else { throw AgentStoreError.invalidValue }
        try profileAction("Reorder provider profiles") {
            try db.queue.write { db in
                let active = try AgentProviderProfile.filter(Column("isDeleted") == false).fetchAll(db)
                let profiles = active.filter { provider == nil || $0.kind == provider }
                guard Set(profiles.map(\.id)) == Set(ids) else { throw AgentStoreError.invalidValue }
                let slots = profiles.map(\.sortOrder).sorted()
                for (order, id) in ids.enumerated() {
                    var profile = profiles.first { $0.id == id }!
                    profile.sortOrder = slots[order]
                    try profile.update(db)
                }
            }
        }
    }

    private static func validProfileName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.contains("\0") else { throw AgentStoreError.invalidValue }
        return name
    }

    public func claudeProfiles(includeDeleted: Bool = false) throws -> [AgentProviderProfile] {
        try providerProfiles(provider: .claude, includeDeleted: includeDeleted)
    }
    public func claudeProfile(nativeProfile: String, includeDeleted: Bool = false) throws -> AgentProviderProfile? {
        try providerProfile(.init(provider: .claude, profile: nativeProfile), includeDeleted: includeDeleted)
    }
    public func saveClaudeProfile(_ profile: AgentProviderProfile) throws {
        guard profile.kind == .claude else { throw AgentStoreError.invalidValue }
        try saveProviderProfile(profile)
    }
    public func createClaudeProfile(name: String, stateDirectory: URL, defaultDirectory: URL) throws -> AgentProviderProfile {
        try createProviderProfile(kind: .claude, name: name, stateDirectory: stateDirectory, claudeDefaultDirectory: defaultDirectory)
    }
    public func authorizeClaudeProfileSignIn(profile: String) throws {
        try authorizeProviderSignIn(.init(provider: .claude, profile: profile))
    }
    public func deleteClaudeProfile(id: UUID) throws {
        guard id != AgentProviderProfile.defaultClaudeID else { throw AgentStoreError.invalidValue }
        try deleteProviderProfile(id: id)
    }
    public func reorderClaudeProfiles(ids: [UUID]) throws {
        try reorderProviderProfiles(ids: ids, provider: .claude)
    }

    private func profileAction<T>(_ summary: String, profileID: UUID? = nil, perform: () throws -> T) throws -> T {
        let tool = ToolDefinition(name: "editProfile", description: summary, parametersJSON: "{}", risk: .reversibleWrite)
        guard AutonomyPolicy().verdict(for: tool, connectorID: "agent.profiles") == .allow else { throw AgentFailure.invalidRequest }
        _ = try record(.init(kind: .toolExecuted, connectorID: "agent.profiles", summary: summary,
            detailJSON: JSONValue.object(["risk": .string(ActionRisk.reversibleWrite.rawValue)]).jsonString,
            sourceID: profileID.map { "providerProfile:" + $0.uuidString }))
        return try perform()
    }

    /// A choice write is atomic for an existing chat and the next new chat.
    /// Validating here prevents a deleted/unknown account from selecting a CLI.
    public func selectAgentChoice(_ choice: AgentProviderChoice, chatID: UUID?, rememberRecent: Bool = false) throws {
        try db.queue.write { db in
            if let chatID, try WorkspaceChat.fetchOne(db, key: chatID) == nil { throw AgentStoreError.missingChat }
            guard try Self.providerProfile(choice, in: db) != nil else { throw AgentStoreError.invalidValue }
            var values = ["agent.lastProvider": choice.provider.rawValue, "agent.lastProfile": choice.id]
            if let chatID {
                values["agent.provider.\(chatID.uuidString)"] = choice.provider.rawValue
                if choice.provider != .local { values[Self.providerProfileKey(choice.provider, chatID: chatID)] = choice.profile }
            }
            if rememberRecent {
                let saved = try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: ["agent.recentProfiles"])
                let recent = saved.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
                let keys = [choice.id] + recent.filter { $0 != choice.id }
                values["agent.recentProfiles"] = String(decoding: try JSONEncoder().encode(Array(keys.prefix(20))), as: UTF8.self)
            }
            for (key, value) in values {
                try db.execute(sql: "INSERT INTO kv(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
            }
        }
    }
    static func providerProfileKey(_ provider: AgentProvider, chatID: UUID) -> String {
        "agent.\(provider.rawValue)Profile.\(chatID.uuidString)"
    }

    public func selectedProviderProfile(chatID: UUID, provider: AgentProvider) throws -> String {
        guard provider != .local else { return "default" }
        let selected = try value(forKey: Self.providerProfileKey(provider, chatID: chatID)) ?? "default"
        return try providerProfile(.init(provider: provider, profile: selected), includeDeleted: true) == nil ? "default" : selected
    }

    public func selectedClaudeProfile(chatID: UUID) throws -> String {
        try selectedProviderProfile(chatID: chatID, provider: .claude)
    }
    public func agentSessions(chatID: UUID) throws -> [AgentChatSession] {
        try db.queue.read { try AgentChatSession.filter(Column("chatID") == chatID).fetchAll($0) }
    }
    public func agentSession(chatID: UUID, choice: AgentProviderChoice) throws -> AgentChatSession? {
        try AgentChatStore(db: db).session(chatID: chatID, provider: choice.provider, profile: choice.profile)
    }
}
