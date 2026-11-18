import Foundation
import GRDB
import AitvarasCore
import AitvarasAgents

extension AgentProviderProfile: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentProviderProfile" }
}

extension Stores {
    public func claudeProfiles(includeDeleted: Bool = false) throws -> [AgentProviderProfile] {
        try db.queue.read { db in
            try AgentProviderProfile.filter(includeDeleted ? SQL("1") : SQL("isDeleted = 0"))
                .order(Column("sortOrder"), Column("createdAt"), Column("id")).fetchAll(db)
        }
    }
    public func claudeProfile(nativeProfile: String, includeDeleted: Bool = false) throws -> AgentProviderProfile? {
        let id = nativeProfile == "default" ? AgentProviderProfile.defaultClaudeID : UUID(uuidString: nativeProfile)
        guard let id else { return nil }
        return try db.queue.read { db in
            guard let value = try AgentProviderProfile.fetchOne(db, key: id), includeDeleted || !value.isDeleted else { return nil }
            return value
        }
    }
    public func saveClaudeProfile(_ profile: AgentProviderProfile) throws {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.kind == .claude, !name.isEmpty, name.count <= 80, !name.contains("\0"),
              !profile.badge.isEmpty, profile.badge.count <= 4,
              ["orange", "blue", "green", "purple", "red"].contains(profile.colour),
              !profile.defaultModel.isEmpty, ["low", "medium", "high", "max"].contains(profile.defaultEffort),
              (profile.id == AgentProviderProfile.defaultClaudeID ? profile.configDirectory == nil && !profile.isDeleted
                : profile.configDirectory?.hasPrefix("/") == true && profile.configDirectory?.contains("\0") == false) else { throw AgentStoreError.invalidValue }
        try profileAction("Save Claude profile", profileID: profile.id) {
            try db.queue.write { db in
                if let old = try AgentProviderProfile.fetchOne(db, key: profile.id) {
                    guard old.configDirectory == profile.configDirectory,
                          !old.isDeleted else { throw AgentStoreError.identityConflict }
                }
                var value = profile; value.name = name
                value.createdAt = try AgentProviderProfile.fetchOne(db, key: profile.id)?.createdAt ?? profile.createdAt
                try value.save(db)
            }
        }
    }
    @discardableResult public func createClaudeProfile(name: String, stateDirectory: URL, defaultDirectory: URL) throws -> AgentProviderProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.contains("\0") else { throw AgentStoreError.invalidValue }
        let id = UUID()
        return try profileAction("Create Claude profile", profileID: id) {
            let directory = try ClaudeProfileDirectory.create(stateDirectory: stateDirectory, defaultDirectory: defaultDirectory, id: id)
            let profiles = try claudeProfiles()
            let colours = ["orange", "blue", "green", "purple", "red"]
            var profile = AgentProviderProfile(id: id, name: name, badge: String(name.prefix(2)),
                colour: colours[profiles.count % colours.count], configDirectory: directory.path,
                sortOrder: (profiles.map(\.sortOrder).max() ?? -1) + 1)
            profile.defaultModel = "opus"; profile.defaultEffort = "medium"
            try db.queue.write { try profile.insert($0) }
            return profile
        }
    }
    public func authorizeClaudeProfileSignIn(profile: String) throws {
        guard let profile = try claudeProfile(nativeProfile: profile) else { throw AgentStoreError.invalidValue }
        try profileAction("Sign in to Claude profile", profileID: profile.id) {}
    }
    public func deleteClaudeProfile(id: UUID) throws {
        guard id != AgentProviderProfile.defaultClaudeID else { throw AgentStoreError.invalidValue }
        try profileAction("Delete Claude profile", profileID: id) {
            try db.queue.write { db in
                guard var profile = try AgentProviderProfile.fetchOne(db, key: id), !profile.isDeleted else { throw AgentStoreError.invalidValue }
                profile.isDeleted = true; try profile.update(db)
            }
        }
        // Native history, CLI credentials and chat rows are retained. This
        // operation removes the selectable account, never the user's data.
    }
    public func reorderClaudeProfiles(ids: [UUID]) throws {
        guard Set(ids).count == ids.count else { throw AgentStoreError.invalidValue }
        try profileAction("Reorder Claude profiles") {
            try db.queue.write { db in
                let profiles = try AgentProviderProfile.filter(Column("isDeleted") == false).fetchAll(db)
                guard Set(profiles.map(\.id)) == Set(ids) else { throw AgentStoreError.invalidValue }
                for (order, id) in ids.enumerated() {
                    var profile = profiles.first { $0.id == id }!; profile.sortOrder = order; try profile.update(db)
                }
            }
        }
    }
    private func profileAction<T>(_ summary: String, profileID: UUID? = nil, perform: () throws -> T) throws -> T {
        let tool = ToolDefinition(name: "editProfile", description: summary, parametersJSON: "{}", risk: .reversibleWrite)
        guard AutonomyPolicy().verdict(for: tool, connectorID: "agent.profiles") == .allow else { throw AgentFailure.invalidRequest }
        _ = try record(.init(kind: .toolExecuted, connectorID: "agent.profiles", summary: summary,
            detailJSON: JSONValue.object(["risk": .string(ActionRisk.reversibleWrite.rawValue)]).jsonString,
            sourceID: profileID.map { "providerProfile:" + $0.uuidString } ?? "provider:claude"))
        return try perform()
    }
    /// A choice write is atomic for an existing chat and the next new chat.
    /// Validating here prevents a deleted/unknown account from selecting a CLI.
    public func selectAgentChoice(_ choice: AgentProviderChoice, chatID: UUID?, rememberRecent: Bool = false) throws {
        try db.queue.write { db in
            if let chatID, try WorkspaceChat.fetchOne(db, key: chatID) == nil { throw AgentStoreError.missingChat }
            if choice.provider == .claude {
                let id = choice.profile == "default" ? AgentProviderProfile.defaultClaudeID : UUID(uuidString: choice.profile)
                guard let id, let profile = try AgentProviderProfile.fetchOne(db, key: id), !profile.isDeleted else { throw AgentStoreError.invalidValue }
            }
            var values = ["agent.lastProvider": choice.provider.rawValue, "agent.lastProfile": choice.id]
            if let chatID {
                values["agent.provider.\(chatID.uuidString)"] = choice.provider.rawValue
                if choice.provider == .claude { values["agent.claudeProfile.\(chatID.uuidString)"] = choice.profile }
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
    public func selectedClaudeProfile(chatID: UUID) throws -> String {
        let selected = try value(forKey: "agent.claudeProfile.\(chatID.uuidString)") ?? "default"
        return try claudeProfile(nativeProfile: selected) == nil ? "default" : selected
    }
    public func agentSessions(chatID: UUID) throws -> [AgentChatSession] {
        try db.queue.read { try AgentChatSession.filter(Column("chatID") == chatID).fetchAll($0) }
    }
    public func agentSession(chatID: UUID, choice: AgentProviderChoice) throws -> AgentChatSession? {
        try AgentChatStore(db: db).session(chatID: chatID, provider: choice.provider, profile: choice.profile)
    }
}
