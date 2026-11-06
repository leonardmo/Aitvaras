import Foundation

public enum AgentAttachmentError: Error, Equatable, Sendable {
    case missingFile, tooLarge, unsupportedType, tooMany
}

/// Bytes are copied at selection time. A later edit, move or deletion of the
/// source cannot change what an explicit Send delivers. No source URL is kept.
public struct AgentAttachment: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case text, image, pdf }
    // Leave room for base64, text and RPC framing in the bounded process pipe.
    public static let maximumBytes = 512 * 1024
    public static let maximumCount = 8
    public let id: UUID
    public let name: String
    public let kind: Kind
    public let mediaType: String
    public let data: Data

    public init(name: String, data: Data) throws {
        try Task.checkCancellation()
        guard data.count <= Self.maximumBytes else { throw AgentAttachmentError.tooLarge }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let type: (Kind, String)
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { type = (.image, "image/png") }
        else if data.starts(with: [0xff, 0xd8, 0xff]) { type = (.image, "image/jpeg") }
        else if data.starts(with: Data("GIF8".utf8)) { type = (.image, "image/gif") }
        else if data.starts(with: Data("RIFF".utf8)), data.count >= 12,
                data.subdata(in: 8..<12) == Data("WEBP".utf8) { type = (.image, "image/webp") }
        else if data.starts(with: Data("%PDF-".utf8)) { type = (.pdf, "application/pdf") }
        else if !["png", "jpg", "jpeg", "gif", "webp", "pdf", "heic", "tiff", "zip"].contains(ext),
                !data.contains(0), String(data: data, encoding: .utf8) != nil { type = (.text, "text/plain") }
        else { throw AgentAttachmentError.unsupportedType }
        id = UUID(); self.name = String(name.prefix(255)); self.data = data
        kind = type.0; mediaType = type.1
    }

    public static func read(_ url: URL) throws -> Self {
        try Task.checkCancellation()
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { throw AgentAttachmentError.missingFile }
        guard (values.fileSize ?? Int.max) <= maximumBytes else { throw AgentAttachmentError.tooLarge }
        // Bound the read as well as checking stat (the file may grow meanwhile).
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw AgentAttachmentError.missingFile }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        try Task.checkCancellation()
        return try Self(name: url.lastPathComponent, data: data)
    }

    var textBlock: String {
        "File \(JSONValue.string(name).jsonString):\n\(String(data: data, encoding: .utf8) ?? "")"
    }
}

extension AgentInput {
    func validateComposerInput(provider: AgentProvider) throws {
        try Task.checkCancellation()
        guard attachments.count <= AgentAttachment.maximumCount else { throw AgentAttachmentError.tooMany }
        guard attachments.reduce(0, { $0 + $1.data.count }) <= AgentAttachment.maximumBytes else { throw AgentAttachmentError.tooLarge }
        if provider == .local, !attachments.isEmpty || command != nil { throw AgentFailure.unsupported }
        if provider == .codex, attachments.contains(where: { $0.kind == .pdf }) { throw AgentAttachmentError.unsupportedType }
        for attachment in attachments {
            let checked = try AgentAttachment(name: attachment.name, data: attachment.data)
            guard checked.kind == attachment.kind, checked.mediaType == attachment.mediaType else { throw AgentAttachmentError.unsupportedType }
        }
    }

    func claudeContent() throws -> JSONValue {
        try validateComposerInput(provider: .claude)
        guard !attachments.isEmpty else { return .string(text) }
        let prompt: [JSONValue] = text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]
        return .array(prompt + attachments.map { file in
            if file.kind == .text { return .object(["type": .string("text"), "text": .string(file.textBlock)]) }
            return .object(["type": .string(file.kind == .image ? "image" : "document"), "source": .object([
                "type": .string("base64"), "media_type": .string(file.mediaType), "data": .string(file.data.base64EncodedString())])])
        })
    }

    func codexContent() throws -> JSONValue {
        try validateComposerInput(provider: .codex)
        var blocks: [JSONValue] = text.isEmpty && !attachments.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]
        blocks += attachments.map { file in
            file.kind == .image
                ? .object(["type": .string("image"), "url": .string("data:\(file.mediaType);base64,\(file.data.base64EncodedString())")])
                : .object(["type": .string("text"), "text": .string(file.textBlock)])
        }
        blocks += mentions.filter { text.contains($0.insertion) }.map {
            .object(["type": .string("mention"), "name": .string($0.name), "path": .string($0.path)])
        }
        if let command, let path = command.skillPath,
           text.split(whereSeparator: \.isWhitespace).contains(where: { $0 == command.insertion }) {
            blocks.append(.object(["type": .string("skill"), "name": .string(command.name), "path": .string(path)]))
        }
        return .array(blocks)
    }

    /// Existing entry payload storage retains the exact selected bytes for a
    /// provably undelivered sign-in retry. Handover reads only entry.text.
    func composerPayload(followup: String? = nil) -> String? {
        var value: [String: JSONValue] = [:]
        if !attachments.isEmpty || !mentions.isEmpty || command != nil,
           let data = try? JSONEncoder().encode(ComposerSnapshot(attachments: attachments, mentions: mentions, command: command)),
           let snapshot = JSONValue.parse(String(decoding: data, as: UTF8.self)) { value["composer"] = snapshot }
        if let followup { value["followup"] = .string(followup) }
        return value.isEmpty ? nil : JSONValue.object(value).jsonString
    }

    public static func restoring(id: UUID, text: String, payload: String?) throws -> AgentInput {
        guard let payload else { return .init(id: id, text: text) }
        guard let value = JSONValue.parse(payload), case .object = value else { throw AgentFailure.invalidRequest }
        guard let raw = value["composer"] else { return .init(id: id, text: text) }
        let saved = try JSONDecoder().decode(ComposerSnapshot.self, from: Data(raw.jsonString.utf8))
        return .init(id: id, text: text, attachments: saved.attachments, mentions: saved.mentions, command: saved.command)
    }
}

private struct ComposerSnapshot: Codable {
    let attachments: [AgentAttachment]
    let mentions: [AgentFileMention]
    let command: AgentCommand?
}
