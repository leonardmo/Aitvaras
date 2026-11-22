import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Resource paths in a reply are scoped to the chat's own working directory
/// and registered project folders.
public struct ChatResourceScope: Hashable, Sendable {
    public let directories: [URL]

    public init(directories: [URL] = []) {
        var seen: Set<URL> = []
        self.directories = directories.filter(\.isFileURL).map {
            Self.canonicalDirectory($0.standardizedFileURL)
        }.filter { seen.insert($0).inserted }
    }

    public static func webURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value) else { return nil }
        switch url.scheme?.lowercased() {
        case "https", "http":
            return url.host()?.isEmpty == false ? url : nil
        case "mailto":
            return url.path().isEmpty ? nil : url
        default:
            return nil
        }
    }

    public func fileURL(_ reference: String) -> URL? {
        guard reference.utf8.count <= 4096, let path = reference.removingPercentEncoding,
              !path.isEmpty, !path.contains("://"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              URLComponents(string: path)?.scheme == nil else { return nil }
        for directory in directories {
            let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
            guard let resolved = Self.canonicalFileURL(candidate), directories.contains(where: { Self.isInside(resolved, root: $0) }),
                  let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]),
                  values.isRegularFile == true || values.isDirectory == true else { continue }
            return resolved
        }
        return nil
    }

    private static func canonicalFileURL(_ url: URL) -> URL? {
        // Foundation abbreviates /private/tmp and /private/var on macOS even
        // after symlink resolution. The descriptor walk needs the actual path.
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private static func canonicalDirectory(_ url: URL) -> URL {
        if let existing = canonicalFileURL(url) { return existing }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url }
        return canonicalDirectory(parent).appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        url.pathComponents.starts(with: root.pathComponents)
    }

    /// Walk from a registered directory using file descriptors. This keeps
    /// automatic reads inside the directory even if a path is replaced after
    /// resolving it, and excludes special files before attempting any read.
    private func rasterData(_ url: URL) -> Data? {
        let cap = 16 * 1024 * 1024
        if directories.contains(where: { Self.isInside(url, root: $0) }) {
            let parts = url.pathComponents.dropFirst()
            guard let name = parts.last else { return nil }
            var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0 else { return nil }
            for component in parts.dropLast() {
                let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                close(parent)
                parent = child
                if parent < 0 { break }
            }
            guard parent >= 0 else { return nil }
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            close(parent)
            guard fd >= 0 else { return nil }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size > 0, info.st_size <= cap else { return nil }
            var data = Data()
            while data.count <= cap,
                  let chunk = try? file.read(upToCount: min(65_536, cap + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
            }
            if !data.isEmpty, data.count <= cap { return data }
        }
        return nil
    }

    public func localImages(in markdown: String) -> [String: CGImage] {
        guard !directories.isEmpty, markdown.contains("![") else { return [:] }
        var images: [String: CGImage] = [:]
        var attempted: Set<String> = []
        func collect(_ nodes: [ChatMarkdownNode]) {
            for node in nodes {
                guard !Task.isCancelled, attempted.count < 8 else { return }
                if node.kind == .imageLink, let path = node.destination,
                   ["png", "jpg", "jpeg"].contains((path as NSString).pathExtension.lowercased()),
                   attempted.insert(path).inserted, let url = fileURL(path),
                   let data = rasterData(url),
                   let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let type = CGImageSourceGetType(source) as String?,
                   type == UTType.png.identifier || type == UTType.jpeg.identifier,
                   let dimensions = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let width = dimensions[kCGImagePropertyPixelWidth] as? Int, (1...8192).contains(width),
                   let height = dimensions[kCGImagePropertyPixelHeight] as? Int, (1...8192).contains(height),
                   width * height <= 32_000_000,
                   let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1200
                   ] as CFDictionary) {
                    images[path] = thumbnail
                }
                collect(node.children)
            }
        }
        collect(ChatMarkdownDocument(markdown).blocks)
        return images
    }
}

public enum ChatPresentation {
    public static let preferenceKey = "chat.formattingGuidance"
    public static let instructions = """
    Aitvaras Chat displays Markdown, tables, math, clickable links, and project-local PNG/JPEG images via ![description](path). For numeric comparisons use a fenced chart block with JSON {"title":"Title","values":[{"label":"A","value":2}]} (up to 16 categories). Write reviews and explanations in regular Markdown. Use language-tagged fences for code. Lead with a concise answer. Use headings, lists, or tables to improve scanning and at most one visual unless asked.
    """
}
