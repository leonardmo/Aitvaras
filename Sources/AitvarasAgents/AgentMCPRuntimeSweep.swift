import Foundation
import Darwin
import AitvarasCore

extension AgentMCPRuntimeFile {
    /// Startup only, before creating any backend. Never traverses links or
    /// removes unrelated files; an unsafe runtime root prevents startup.
    public static func sweep(stateDirectory: URL, policy: AutonomyPolicy = .init(),
                             audit: @escaping AgentActionCoordinator.Audit) async throws {
        let tool = ToolDefinition(name: "runtimeCleanup", description: "Remove stale MCP runtime files", parametersJSON: "{}", risk: .reversibleWrite)
        guard policy.verdict(for: tool, connectorID: "agent.mcp") == .allow else { throw AgentMCPError.runtimeFile }
        let root = open(stateDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw AgentMCPError.runtimeFile }
        defer { close(root) }
        guard let runtime = try privateDirectory(root, name: "Runtime") else { return }
        defer { close(runtime) }
        guard let mcp = try privateDirectory(runtime, name: "mcp") else { return }
        defer { close(mcp) }
        try await audit(.init(kind: .toolExecuted, connectorID: "agent.mcp", summary: "MCP startup cleanup authorized"))
        for project in try names(mcp) where UUID(uuidString: project) != nil {
            var entry = stat()
            guard fstatat(mcp, project, &entry, AT_SYMLINK_NOFOLLOW) == 0 else { throw AgentMCPError.runtimeFile }
            guard entry.st_mode & S_IFMT == S_IFDIR else { continue }
            guard let directory = try privateDirectory(mcp, name: project) else { continue }
            defer { close(directory) }
            for name in try names(directory) where name.hasSuffix(".json") && UUID(uuidString: String(name.dropLast(5))) != nil {
                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw AgentMCPError.runtimeFile }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else { continue }
                guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else { throw AgentMCPError.runtimeFile }
            }
        }
        try await audit(.init(kind: .toolExecuted, connectorID: "agent.mcp", summary: "MCP startup cleanup completed"))
    }

    private static func privateDirectory(_ parent: Int32, name: String) throws -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw AgentMCPError.runtimeFile }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw AgentMCPError.runtimeFile
        }
        return fd
    }

    private static func names(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw AgentMCPError.runtimeFile }
        guard let directory = fdopendir(copy) else { close(copy); throw AgentMCPError.runtimeFile }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw AgentMCPError.runtimeFile }; break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= 4096 else { throw AgentMCPError.runtimeFile }
        }
        return result.sorted()
    }
}
