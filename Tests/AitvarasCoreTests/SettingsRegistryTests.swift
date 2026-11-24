import Foundation
import Testing
import AitvarasAgent
import AitvarasAgents
import AitvarasStore

@Suite(.timeLimit(.minutes(1))) struct SettingsRegistryTests {
    @Test func stableIDsHaveOneSupportedHomeAndUserOnlySettingsCannotBeProposed() throws {
        let panes: Set<String> = ["overview", "providers", "models", "cloud", "connections", "routines",
                                  "background", "avatar", "voice", "capture", "memory", "access", "usage"]
        let project: Set<String> = ["general", "folders", "agent", "codex", "gateway", "servers"]
        #expect(Set(SettingsRegistry.entries.map(\.id)).count == SettingsRegistry.entries.count)
        for setting in SettingsRegistry.entries {
            #expect(SettingsRegistry[setting.id] == setting)
            #expect((setting.scope == .profile ? panes : project).contains(setting.destination))
            if setting.risk == .userOnly { #expect(!setting.acceptsValueProposal) }
        }
        let volume = try #require(SettingsRegistry["voice.volume"])
        #expect(volume.valueType.accepts(.number(1.25)))
        #expect(!volume.valueType.accepts(.number(12)))
        #expect(!volume.valueType.accepts(.string("1")))
        #expect(SettingsRegistry["access.mail"]?.acceptsValueProposal == false)
    }

    @Test func tcpAndStdioDraftsValidateWithoutCredentials() throws {
        var known = try #require(SettingsMCPDraft.catalog("linear"))
        try known.validate()
        #expect(known.auth == .oauth)
        let draft = try SettingsMCPDraft.decode(.object([
            "name": .string("example"), "label": .string("Example"), "transport": .string("stdio"),
            "auth": .string("none"), "command": .string("example-mcp"), "secretEnvironment": .array([.string("AUTH_TOKEN")])
        ]))
        #expect(draft.secretEnvironment == ["AUTH_TOKEN"])
        #expect(draft.environment.isEmpty)
        var invalid = draft
        invalid.secretEnvironment = []
        invalid.environment = ["AUTH_TOKEN": "example"]
        #expect(throws: SettingsToolError.invalidDraft) { try invalid.validate() }
        var badURL = known
        badURL.url = "https://example.invalid/mcp?key=example"
        #expect(throws: SettingsToolError.invalidDraft) { try badURL.validate() }
    }

    @Test func gatewayRoutesSetupToTheVerifiedProjectWithoutApplyingSettings() async throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let service = GatewayToolService(stores: stores, hub: ConnectorHub(stores: stores),
            approvals: GatewayApprovalBroker(), settings: { tool, arguments, source in
                #expect(source.projectID == project.id)
                #expect(tool == "propose")
                #expect(arguments["changes"]?["appearance.mode"] == .string("light"))
                return "Waiting for review"
            })
        let gateway = service.connect(invocation: gatewayFixtureInvocation(projectID: project.id), authorize: {})
        await gatewayReady(gateway)
        let result = await gatewayCall(gateway, name: "settings_propose", arguments: [
            "changes": .object(["appearance.mode": .string("light")]), "reason": .string("Review the palette")
        ])
        #expect(gatewayText(result) == "Waiting for review")
        #expect(try stores.value(forKey: "appearance.mode") == nil)
    }
}
