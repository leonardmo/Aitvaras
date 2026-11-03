import Foundation

/// The single bounded metadata block used by local workspace turns and their
/// preview. It grants no capabilities and never reads evidence or files.
public enum WorkspaceTextContext {
    public static let maximumCharacters = 8_000
    public static let clippingMarker = "\n[Project instructions and chat purpose clipped at the context limit.]"

    public static func bounded(_ text: String) -> String {
        text.count <= maximumCharacters ? text
            : String(text.prefix(maximumCharacters - clippingMarker.count)) + clippingMarker
    }
}

public enum WorkspacePolicyStatus: String, Codable, Sendable, Equatable {
    case unreviewed, reviewed, stale
}

public struct WorkspaceContextManifest: Sendable, Equatable {
    public let includedCategories: [String]
    public let excludedCategories: [String]
    public let maximumCharacters: Int
    public let originalCharacters: Int
    public let includedCharacters: Int
    public let wasClipped: Bool
    public let destination: String
    public let summary: String

    public init(originalCharacters: Int, includedCharacters: Int) {
        includedCategories = ["Project title", "Chat title", "Chat purpose", "Project instructions"]
        excludedCategories = ["Native provider transcripts", "Registered folder contents", "Capture text and summaries",
                              "Other chats", "Shared memories", "Global RAG", "Connectors and tools"]
        maximumCharacters = WorkspaceTextContext.maximumCharacters
        self.originalCharacters = originalCharacters
        self.includedCharacters = includedCharacters
        wasClipped = originalCharacters > maximumCharacters
        destination = "On-device only; no cloud export"
        summary = "Project and chat metadata only. This chat's bounded typed history and the current user message are supplied separately. No files, imported histories, captures, tools or shared recall."
    }
}

public struct WorkspaceContextPacket: Sendable, Equatable {
    public let projectID: UUID
    public let chatID: UUID
    public let promptText: String
    public let manifest: WorkspaceContextManifest
    public let policyStatus: WorkspacePolicyStatus
    public let policyRevision: Int?
    public let localOnly = true

    public init(projectID: UUID, chatID: UUID, promptText: String, manifest: WorkspaceContextManifest,
                policyStatus: WorkspacePolicyStatus, policyRevision: Int?) {
        self.projectID = projectID; self.chatID = chatID; self.promptText = promptText
        self.manifest = manifest; self.policyStatus = policyStatus; self.policyRevision = policyRevision
    }
}
