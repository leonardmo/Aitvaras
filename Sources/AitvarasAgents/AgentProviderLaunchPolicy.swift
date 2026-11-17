import Foundation

/// Only the new chat path uses this seam. Legacy client guards stay intact.
public enum AgentProviderLaunchPolicy {
    public static func isTestConfiguration(environment: [String: String], isolated: Bool) -> Bool {
        isolated && (environment["AITVARAS_AGENT_TEST_PROVIDERS"] == "real"
            || environment["AITVARAS_FAKE_CLAUDE"] != nil || environment["AITVARAS_FAKE_CODEX"] != nil)
    }
    public static func allowsProviders(environment: [String: String], isolated: Bool) -> Bool {
        isTestConfiguration(environment: environment, isolated: isolated)
            || (environment["AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS"] != "1"
                && environment["AITVARAS_UI_TEST_MODE"] != "1"
                && environment["AITVARAS_AGENT_TEST_PROVIDERS"] == nil
                && environment["AITVARAS_FAKE_CLAUDE"] == nil && environment["AITVARAS_FAKE_CODEX"] == nil)
    }
    public static func executable(_ provider: AgentProvider, environment: [String: String], isolated: Bool) -> URL? {
        guard provider != .local, isolated, let path = environment[provider == .claude ? "AITVARAS_FAKE_CLAUDE" : "AITVARAS_FAKE_CODEX"],
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
    public static func allows(_ provider: AgentProvider, environment: [String: String], isolated: Bool) -> Bool {
        if provider == .local { return true }
        guard allowsProviders(environment: environment, isolated: isolated) else { return false }
        if isTestConfiguration(environment: environment, isolated: isolated),
           environment["AITVARAS_AGENT_TEST_PROVIDERS"] != "real" {
            return executable(provider, environment: environment, isolated: isolated) != nil
        }
        return true
    }
}
