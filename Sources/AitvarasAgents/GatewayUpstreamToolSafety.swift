import AitvarasCore

/// Shared by gateway enforcement and the project settings editor.
public enum GatewayUpstreamToolSafety {
    public static func isForbidden(_ tool: MCPGatewayTool) -> Bool {
        guard case .upstream = tool.origin else { return false }
        let name = tool.name.lowercased()
        return ["mail", "smtp", "outlook", "calendar", "reminder"].contains(where: name.contains)
            || AgentToolPolicy.isCommandExecution(.init(name: tool.definition.name, input: .null))
    }

    public static func confirmationReason(_ tool: MCPGatewayTool) -> String? {
        guard case .upstream = tool.origin else { return nil }
        let name = tool.definition.name.lowercased()
        if name.contains("delete") || name.contains("remove") { return "This tool can delete or remove data." }
        if tool.annotations.destructive == true { return "This tool is declared destructive." }
        return AgentToolPolicy.criticalMCPApprovalReason(toolName: tool.definition.name)
    }
}
