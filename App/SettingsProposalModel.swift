import Foundation
import AitvarasAgent
import AitvarasAgents
import AitvarasCore
import AitvarasStore
import AitvarasVoice

@MainActor extension AppModel {
    private static let settingsProposalKey = "settings.proposals.v1"

    func loadSettingsProposals() throws {
        guard let raw = try stores?.value(forKey: Self.settingsProposalKey) else { return }
        settingsProposals = try JSONDecoder().decode([SettingsProposal].self, from: Data(raw.utf8))
    }

    func executeSettingsTool(_ name: String, arguments: JSONValue, source: SettingsProposalSource) throws -> String {
        guard case .object(let fields) = arguments, arguments.jsonString.utf8.count <= 24_000, let stores
        else { throw SettingsToolError.invalidArguments }
        try validateSettingsSource(source, stores: stores)
        switch name {
        case "read":
            guard Set(fields.keys).isSubset(of: ["id"]) else { throw SettingsToolError.invalidArguments }
            let definitions: [AitvarasSetting]
            if let id = fields["id"] {
                guard let key = id.stringValue else { throw SettingsToolError.invalidArguments }
                definitions = [try setting(key, source: source)]
            } else {
                definitions = SettingsRegistry.entries.filter { $0.scope == .profile || source.projectID != nil }
            }
            let items = try definitions.map { definition in
                try describeSetting(definition, source: source, stores: stores, includeValue: fields["id"] != nil)
            }
            return JSONValue.array(items).jsonString
        case "open":
            guard Set(fields.keys) == ["id"], let key = fields["id"]?.stringValue else { throw SettingsToolError.invalidArguments }
            let definition = try setting(key, source: source)
            openSetting(definition, source: source)
            return "Opened the setting in Aitvaras."
        case "propose":
            guard Set(fields.keys) == ["changes", "reason"], case .object(let requested)? = fields["changes"],
                  (1...8).contains(requested.count) else { throw SettingsToolError.invalidArguments }
            let reason = try settingsProposalReason(fields["reason"])
            let changes = try requested.keys.sorted().compactMap { key -> SettingsValueChange? in
                let definition = try setting(key, source: source)
                guard definition.risk != .userOnly, definition.acceptsValueProposal else { throw SettingsToolError.userOnly }
                guard var next = requested[key], definition.valueType.accepts(next),
                      let before = try settingsValue(key, source: source, stores: stores) else { throw SettingsToolError.invalidValue }
                if key == "project.name" {
                    guard let name = next.stringValue, !name.isEmpty,
                          name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { throw SettingsToolError.invalidValue }
                }
                if key == "project.folders" {
                    let paths = try Set(settingFolderPaths(next)).union(settingFolderPaths(before))
                    guard paths.count <= 16 else { throw SettingsToolError.invalidValue }
                    next = .array(paths.sorted().map(JSONValue.string))
                }
                if key == "project.gatewayTools" {
                    next = .array(try settingToolScopes(next).map { .string($0.rawValue) }.sorted { $0.jsonString < $1.jsonString })
                }
                if key == "routines.status" {
                    guard case .object(let current) = before, case .object(let delta) = next,
                          delta.count == 1, let (routineID, status) = delta.first,
                          current[routineID] != nil, [.string("active"), .string("paused")].contains(status)
                    else { throw SettingsToolError.invalidValue }
                    next = .object(current.merging(delta) { _, new in new })
                }
                guard next != before else { return nil }
                return SettingsValueChange(id: key, before: before, after: next)
            }
            guard !changes.isEmpty else { return "The requested values are already set." }
            return try queueSettingsProposal(.init(source: source, reason: reason, changes: changes), stores: stores)
        case "connections_propose":
            guard Set(fields.keys).isSubset(of: ["reason", "catalog", "draft"]),
                  (fields["catalog"] == nil) != (fields["draft"] == nil) else { throw SettingsToolError.invalidArguments }
            let reason = try settingsProposalReason(fields["reason"])
            let draft: SettingsMCPDraft
            if let key = fields["catalog"]?.stringValue, let known = SettingsMCPDraft.catalog(key) { draft = known }
            else if let value = fields["draft"] { draft = try SettingsMCPDraft.decode(value) }
            else { throw SettingsToolError.invalidDraft }
            guard draft.global || source.projectID != nil else { throw SettingsToolError.unavailable }
            return try queueSettingsProposal(.init(source: source, reason: reason, server: draft), stores: stores)
        default:
            throw SettingsToolError.unavailable
        }
    }

    func openSetting(_ definition: AitvarasSetting, source: SettingsProposalSource) {
        switch definition.scope {
        case .profile:
            if let page = SettingsPage(rawValue: definition.destination) {
                SettingsNavigation.open(.page(page), settingID: definition.id)
            }
        case .project:
            if let id = source.projectID, let section = ProjectSettingsSection(rawValue: definition.destination) {
                SettingsNavigation.open(.project(id, section: section), settingID: definition.id)
            }
        }
    }

    func applySettingsProposal(_ id: UUID, item: String? = nil) throws {
        guard let stores, let index = settingsProposals.firstIndex(where: { $0.id == id && $0.status == .waiting }) else {
            throw SettingsToolError.stale
        }
        var proposal = settingsProposals[index]
        guard proposal.server == nil else { throw SettingsToolError.userOnly }
        try validateSettingsSource(proposal.source, stores: stores)
        let changes = proposal.changes.filter { item == nil || $0.id == item }
        guard !changes.isEmpty else { throw SettingsToolError.stale }
        try applySettingsChanges(changes, undo: false, proposal: proposal, stores: stores) {
            proposal.appliedChanges += changes
            proposal.changes.removeAll { change in changes.contains { $0.id == change.id } }
            if proposal.changes.isEmpty { proposal.status = .applied }
            try updateSettingsProposal(proposal, at: index, stores: stores)
        }
    }

    func editSettingsProposal(_ id: UUID, values: [String: JSONValue]) throws {
        guard let stores, let index = settingsProposals.firstIndex(where: { $0.id == id && $0.status == .waiting }),
              settingsProposals[index].server == nil else { throw SettingsToolError.stale }
        var proposal = settingsProposals[index]
        try validateSettingsSource(proposal.source, stores: stores)
        guard Set(values.keys) == Set(proposal.changes.map(\.id)) else { throw SettingsToolError.invalidValue }
        proposal.changes = try proposal.changes.map { change in
            guard let setting = SettingsRegistry[change.id], let value = values[change.id],
                  setting.acceptsValueProposal, setting.valueType.accepts(value) else { throw SettingsToolError.invalidValue }
            if change.id == "project.folders" {
                let paths = try settingFolderPaths(value)
                guard Set(try settingFolderPaths(change.before)).isSubset(of: paths) else { throw SettingsToolError.invalidValue }
                return .init(id: change.id, before: change.before, after: .array(paths.map(JSONValue.string)))
            }
            return .init(id: change.id, before: change.before, after: value)
        }
        try updateSettingsProposal(proposal, at: index, stores: stores)
    }

    func undoSettingsProposal(_ id: UUID) throws {
        guard let stores, let index = settingsProposals.firstIndex(where: { $0.id == id }),
              settingsProposals[index].server == nil, !settingsProposals[index].appliedChanges.isEmpty
        else { throw SettingsToolError.stale }
        var proposal = settingsProposals[index]
        try validateSettingsSource(proposal.source, stores: stores)
        try applySettingsChanges(proposal.appliedChanges, undo: true, proposal: proposal, stores: stores) {
            proposal.appliedChanges = []
            if proposal.status == .applied { proposal.status = .undone }
            try updateSettingsProposal(proposal, at: index, stores: stores)
        }
    }

    func rejectSettingsProposal(_ id: UUID) throws {
        guard let stores, let index = settingsProposals.firstIndex(where: { $0.id == id && $0.status == .waiting })
        else { throw SettingsToolError.stale }
        var proposal = settingsProposals[index]
        proposal.status = .rejected
        try recordSettingsApproval(.suggestionRejected, "Rejected a settings proposal", proposal: proposal, stores: stores)
        try updateSettingsProposal(proposal, at: index, stores: stores)
    }

    func markMCPProposalInstalled(_ id: UUID, draft: SettingsMCPDraft, accountID: UUID?) throws {
        guard let stores, let index = settingsProposals.firstIndex(where: { $0.id == id && $0.status == .waiting }),
              settingsProposals[index].server != nil else { throw SettingsToolError.stale }
        var proposal = settingsProposals[index]
        proposal.status = .installed
        proposal.server = draft
        proposal.serverAccountID = accountID
        try recordSettingsApproval(.toolExecuted, "Applied an MCP setup proposal", proposal: proposal, stores: stores)
        try updateSettingsProposal(proposal, at: index, stores: stores)
    }

    func completeMCPProposal(_ id: UUID) throws {
        guard let stores, let index = settingsProposals.firstIndex(where: { $0.id == id && $0.status == .installed })
        else { throw SettingsToolError.stale }
        var proposal = settingsProposals[index]
        proposal.status = .applied
        try updateSettingsProposal(proposal, at: index, stores: stores)
    }

    func recordSettingsApproval(_ kind: ActivityEvent.Kind, _ summary: String, proposal: SettingsProposal, stores: Stores) throws {
        // Keep the audit useful without tool arguments, URLs, paths or named credentials.
        let detail: JSONValue = .object([
            "settings": .array((proposal.changes + proposal.appliedChanges).map { .string($0.id) }),
            "channel": .string(proposal.source.channel),
            "scope": .string(proposal.source.projectID == nil || proposal.server?.global == true ? "profile" : "project")
        ])
        try stores.recordGatewayActivity(.init(id: kind == .suggestionOffered ? proposal.id : UUID(),
            kind: kind, connectorID: "settings", summary: summary,
            detailJSON: detail.jsonString, causedBy: kind == .suggestionOffered ? nil : proposal.id,
            sourceID: proposal.id.uuidString),
            projectID: proposal.source.projectID)
    }

    private func describeSetting(_ definition: AitvarasSetting, source: SettingsProposalSource, stores: Stores,
                                 includeValue: Bool) throws -> JSONValue {
        var item: [String: JSONValue] = [
            "id": .string(definition.id), "title": .string(definition.title), "scope": .string(definition.scope.rawValue),
            "risk": .string(definition.risk.rawValue), "home": .string(definition.destination),
            "allowed": definition.valueType.schema, "proposable": .bool(definition.acceptsValueProposal)
        ]
        if let hint = definition.hint { item["help"] = .string(hint) }
        if includeValue, let current = try settingsValue(definition.id, source: source, stores: stores),
           !["project.instructions", "project.folders"].contains(definition.id) || source.channel == "local" {
            item["current"] = current
        }
        return .object(item)
    }

    private func validateSettingsSource(_ source: SettingsProposalSource, stores: Stores) throws {
        if let project = source.projectID, try stores.workspaceProject(id: project) == nil {
            throw SettingsToolError.unavailable
        }
        if let id = source.chatID {
            guard let chat = try stores.workspaceChat(id: id), chat.archivedAt == nil, chat.projectID == source.projectID
            else { throw SettingsToolError.unavailable }
        }
    }

    private func setting(_ id: String, source: SettingsProposalSource) throws -> AitvarasSetting {
        guard let definition = SettingsRegistry[id], definition.scope == .profile || source.projectID != nil
        else { throw SettingsToolError.unavailable }
        return definition
    }

    private func settingsProposalReason(_ raw: JSONValue?) throws -> String {
        guard let reason = raw?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty, reason.utf8.count <= 500, !reason.contains("\0")
        else { throw SettingsToolError.invalidArguments }
        return reason
    }

    private func queueSettingsProposal(_ proposal: SettingsProposal, stores: Stores) throws -> String {
        let history = settingsProposals.filter { $0.source == proposal.source }
        let match = history.last { item in
            item.server == proposal.server && item.changes.map(\.id) == proposal.changes.map(\.id)
                && item.changes.map(\.after) == proposal.changes.map(\.after)
        }
        if match?.status == .rejected { throw SettingsToolError.rejected }
        if let match, match.status == .waiting { return "Already waiting for review (\(match.id.uuidString))." }
        guard history.count(where: { $0.status == .waiting }) < 4,
              history.last.map({ proposal.createdAt.timeIntervalSince($0.createdAt) >= 3 }) ?? true,
              settingsProposals.count(where: { $0.status == .waiting }) < 40 else { throw SettingsToolError.rateLimited }
        let next = Array((settingsProposals + [proposal]).suffix(100))
        try recordSettingsApproval(.suggestionOffered, "Settings proposal ready for review", proposal: proposal, stores: stores)
        try saveSettingsProposals(next, stores: stores)
        if proposal.source.chatID == nil {
            NotificationRouter.requestedWorkNeedsAttention(message: "A settings proposal is ready to review in Aitvaras.")
        }
        return "Waiting for the user's review (\(proposal.id.uuidString)). No settings have been changed."
    }

    private func updateSettingsProposal(_ proposal: SettingsProposal, at index: Int, stores: Stores) throws {
        var next = settingsProposals
        next[index] = proposal
        try saveSettingsProposals(next, stores: stores)
    }

    private func saveSettingsProposals(_ values: [SettingsProposal], stores: Stores) throws {
        try stores.setValue(AgentMCPConfiguration.encode(values), forKey: Self.settingsProposalKey)
        settingsProposals = values
    }

    private func applySettingsChanges(_ changes: [SettingsValueChange], undo: Bool, proposal: SettingsProposal,
                                      stores: Stores, save: () throws -> Void) throws {
        guard AutonomyPolicy().verdict(for: .confirmable, hasExactGrant: false, requiresExplicitConfirmation: true)
            == .requireConfirmation else { throw SettingsToolError.unavailable }
        for change in changes {
            guard SettingsRegistry[change.id]?.acceptsValueProposal == true,
                  try settingsValue(change.id, source: proposal.source, stores: stores) == (undo ? change.after : change.before)
            else { throw SettingsToolError.stale }
        }
        try recordSettingsApproval(.suggestionAccepted, undo ? "Approved settings undo" : "Approved settings changes",
                                   proposal: proposal, stores: stores)
        var applied: [SettingsValueChange] = []
        do {
            for change in changes {
                try writeSetting(change.id, value: undo ? change.before : change.after, projectID: proposal.source.projectID, stores: stores)
                applied.append(change)
            }
            try save()
        } catch {
            for change in applied.reversed() {
                try? writeSetting(change.id, value: undo ? change.after : change.before, projectID: proposal.source.projectID, stores: stores)
            }
            try? recordSettingsApproval(.agentFailure, "Settings change failed", proposal: proposal, stores: stores)
            throw error
        }
        try recordSettingsApproval(.toolExecuted, undo ? "Restored prior setting values" : "Applied approved setting values",
                                   proposal: proposal, stores: stores)
    }

    private func settingsValue(_ id: String, source: SettingsProposalSource, stores: Stores) throws -> JSONValue? {
        switch id {
        case "appearance.mode": .string(AppAppearance.shared.mode.rawValue)
        case "companion.presentation": .string(companionPresentation.rawValue)
        case "companion.character": .string(AitvarasPreferences.current.string(forKey: "avatar.style") ?? "creature")
        case "voice.language": .string(AitvarasPreferences.current.string(forKey: "voice.locale") ?? "en-US")
        case "voice.volume": .number(AitvarasPreferences.current.object(forKey: "voice.volume") as? Double ?? 1)
        case "capture.language": .string(CaptureSettings.load().language.rawValue)
        case "capture.postprocessing": .string(CaptureSettings.load().postprocessing.rawValue)
        case "capture.audioRetention": .string(CaptureSettings.load().audioRetention.rawValue)
        case "memory.schedule.mode": .string(NightlyScheduleSettings.load().mode.rawValue)
        case "memory.schedule.power": .string(NightlyScheduleSettings.load().powerPolicy.rawValue)
        case "memory.schedule.earliestMinute": .number(Double(NightlyScheduleSettings.load().earliestMinute))
        case "memory.schedule.fixedMinute": .number(Double(NightlyScheduleSettings.load().fixedMinute))
        case "memory.schedule.wakeDelay": .number(Double(NightlyScheduleSettings.load().wakeDelayMinutes))
        case "memory.schedule.batteryThreshold": .number(Double(NightlyScheduleSettings.load().batteryThreshold))
        case "background.paused": .bool(try stores.backgroundWorkPolicy().paused)
        case "routines.status": .object(try routineStatuses(stores))
        case "project.gatewayTools":
            if let projectID = source.projectID {
                .array(try stores.gatewayToolScopeSettings(projectID: projectID).scopes.sorted {
                    $0.rawValue < $1.rawValue
                }.map { .string($0.rawValue) })
            } else { nil }
        case "project.folders":
            if let projectID = source.projectID {
                .array(try stores.workspaceFolders(projectID: projectID).map { .string($0.path) })
            } else { nil }
        case "project.name", "project.instructions":
            if let projectID = source.projectID, let project = try stores.workspaceProject(id: projectID) {
                .string(id == "project.name" ? project.title : project.instructions)
            } else { nil }
        default: nil
        }
    }

    private func routineStatuses(_ stores: Stores) throws -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: try stores.commandRoutines()
            .filter { ["active", "paused"].contains($0.status) }
            .map { ($0.id.uuidString, .string($0.status)) })
    }

    private func settingToolScopes(_ value: JSONValue) throws -> Set<GatewayToolScope> {
        guard let values = value.arrayValue else { throw SettingsToolError.invalidValue }
        let scopes = values.compactMap { $0.stringValue.flatMap(GatewayToolScope.init(rawValue:)) }
        guard scopes.count == values.count, !scopes.contains(.settings), Set(scopes).count == values.count
        else { throw SettingsToolError.invalidValue }
        return Set(scopes)
    }

    private func settingFolderPaths(_ value: JSONValue) throws -> [String] {
        guard let items = value.arrayValue, items.count <= 16 else { throw SettingsToolError.invalidValue }
        let paths = items.compactMap(\.stringValue)
        guard paths.count == items.count,
              paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 1_024 && !$0.contains("\0") })
        else { throw SettingsToolError.invalidValue }
        let resolved = paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path }
        guard Set(resolved).count == paths.count else { throw SettingsToolError.invalidValue }
        return resolved.sorted()
    }

    private func writeSetting(_ id: String, value: JSONValue, projectID: UUID?, stores: Stores) throws {
        let text = value.stringValue ?? ""
        if id.hasPrefix("capture.") {
            var settings = CaptureSettings.load()
            switch id {
            case "capture.language": settings.language = CaptureLanguage(rawValue: text) ?? settings.language
            case "capture.postprocessing": settings.postprocessing = CapturePostprocessing(rawValue: text) ?? settings.postprocessing
            case "capture.audioRetention": settings.audioRetention = CaptureAudioRetention(rawValue: text) ?? settings.audioRetention
            default: throw SettingsToolError.userOnly
            }
            settings.save()
        } else if id.hasPrefix("memory.schedule.") {
            var settings = NightlyScheduleSettings.load()
            let number = Int(value.doubleValue ?? 0)
            switch id {
            case "memory.schedule.mode": settings.mode = NightlyScheduleMode(rawValue: text) ?? settings.mode
            case "memory.schedule.power": settings.powerPolicy = NightlyPowerPolicy(rawValue: text) ?? settings.powerPolicy
            case "memory.schedule.earliestMinute": settings.earliestMinute = number
            case "memory.schedule.fixedMinute": settings.fixedMinute = number
            case "memory.schedule.wakeDelay": settings.wakeDelayMinutes = number
            case "memory.schedule.batteryThreshold": settings.batteryThreshold = number
            default: throw SettingsToolError.userOnly
            }
            updateNightlySchedule(settings)
        } else {
            switch id {
            case "appearance.mode":
                guard let mode = AppAppearanceMode(rawValue: text) else { throw SettingsToolError.invalidValue }
                AppAppearance.shared.select(mode)
            case "companion.presentation":
                guard let mode = CompanionPresentation(rawValue: text) else { throw SettingsToolError.invalidValue }
                companionPresentation = mode
            case "companion.character":
                AitvarasPreferences.current.set(text, forKey: "avatar.style")
            case "voice.language": setVoiceLanguage(text)
            case "voice.volume": AitvarasPreferences.current.set(value.doubleValue ?? 1, forKey: "voice.volume")
            case "routines.status":
                let existing = try routineStatuses(stores)
                guard case .object(let new) = value, Set(new.keys) == Set(existing.keys) else {
                    throw SettingsToolError.invalidValue
                }
                let differences = new.filter { existing[$0.key] != $0.value }
                guard differences.count == 1, let (id, setting) = differences.first,
                      let routine = UUID(uuidString: id), let newStatus = setting.stringValue,
                      ["active", "paused"].contains(newStatus),
                      let status = CommandRoutine.Status(rawValue: newStatus) else { throw SettingsToolError.invalidValue }
                try stores.setCommandRoutineStatus(routine, to: status)
            case "project.gatewayTools":
                guard let projectID else { throw SettingsToolError.unavailable }
                let current = try stores.gatewayToolScopeSettings(projectID: projectID)
                _ = try stores.saveGatewayToolScopes(projectID: projectID, scopes: settingToolScopes(value),
                                                   expectedRevision: current.revision)
                Task { await refreshGatewayRouting() }
            case "background.paused":
                guard let isPaused = value.boolValue else { throw SettingsToolError.invalidValue }
                var policy = try stores.backgroundWorkPolicy()
                policy.paused = isPaused
                try stores.saveBackgroundWorkPolicy(policy)
            case "project.folders":
                guard let projectID, let project = try stores.workspaceProject(id: projectID) else {
                    throw SettingsToolError.unavailable
                }
                let review = try stores.workspacePolicyReview(projectID: projectID)
                let policy = try stores.workspacePolicy(projectID: projectID)
                let paths = try settingFolderPaths(value)
                let drafts = paths.map { path in
                    WorkspaceFolderDraft(path: path, access: review.folders.first(where: { $0.path == path })?.access ?? .readOnly)
                }
                _ = try stores.saveWorkspaceProjectSettings(projectID: projectID, title: project.title,
                    instructions: project.instructions, folders: drafts, allowedProviders: policy?.allowedProviders ?? [.local],
                    expectedContextRevision: review.revision, expectedPolicyRevision: policy?.revision,
                    expectedProjectTitle: project.title)
                refreshWorkspaces()
            case "project.name", "project.instructions":
                guard let projectID, var project = try stores.workspaceProject(id: projectID) else {
                    throw SettingsToolError.unavailable
                }
                if id == "project.name" { project.title = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                else { project.instructions = text }
                try stores.saveWorkspaceProject(project)
                refreshWorkspaces()
            default: throw SettingsToolError.userOnly
            }
        }
    }
}
