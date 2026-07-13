import Foundation
import PDFKit

/// Chunking strategies for the RAG index (D11): Markdown-heading-aware for
/// notes, declaration-aware for code, per-page for PDFs, paragraph packing
/// for everything else. All pure functions — the Indexer picks by extension.
public enum Chunker {
    public typealias Piece = (text: String, context: String?)

    /// Soft maximum chunk size in characters.
    public static let targetSize = 1200
    /// Pieces below this are merged into a neighbour rather than emitted alone.
    public static let minSize = 200

    static let windowLines = 60
    static let windowOverlap = 10

    // MARK: Markdown

    /// Splits at headings (# … ###), carrying the heading path as context
    /// ("ML Notes › Backprop"). Long sections split at paragraph boundaries.
    public static func markdown(_ content: String) -> [Piece] {
        var pieces: [Piece] = []
        var path: [(level: Int, title: String)] = []
        var section: [String] = []
        var inFence = false

        func flush() {
            let text = section.joined(separator: "\n")
            section.removeAll()
            let context = path.isEmpty ? nil : path.map(\.title).joined(separator: " › ")
            for part in splitSection(text) {
                pieces.append((part, context))
            }
        }

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
            }
            if !inFence, let (level, title) = headingLine(line) {
                flush()
                path.removeAll { $0.level >= level }
                path.append((level, title))
            } else {
                section.append(String(line))
            }
        }
        flush()
        return pieces
    }

    private static func headingLine(_ line: Substring) -> (Int, String)? {
        guard line.first == "#" else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 3, line.dropFirst(hashes.count).first == " " else { return nil }
        let title = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (hashes.count, title)
    }

    // MARK: Code

    private static let declarationKeywords: Set<String> = [
        "func", "class", "struct", "enum", "def", "function"
    ]
    private static let modifierTokens: Set<String> = [
        "public", "private", "fileprivate", "internal", "open", "final",
        "static", "override", "required", "dynamic", "indirect",
        "export", "default", "async", "abstract"
    ]

    /// Splits at top-level declarations where cheap (keyword at column 0,
    /// modifiers allowed); tiny segments merge forward, oversized ones and
    /// files without declarations fall back to a 60-line window with
    /// 10 lines of overlap. Context is the covered line range.
    public static func code(_ content: String) -> [Piece] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var boundaries = lines.indices.filter { isTopLevelDeclaration(lines[$0]) }
        guard boundaries.count >= 2 else { return windowed(lines, range: lines.indices) }
        if boundaries.first != 0 { boundaries.insert(0, at: 0) }

        var pieces: [Piece] = []
        var currentStart: Int?
        var currentText = ""

        func emit(endLine: Int) {
            guard let start = currentStart else { return }
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append((text, "lines \(start + 1)–\(endLine)")) }
            currentStart = nil
            currentText = ""
        }

        for (i, start) in boundaries.enumerated() {
            let end = i + 1 < boundaries.count ? boundaries[i + 1] : lines.count
            if end - start > windowLines + 2 * windowOverlap {
                emit(endLine: start)
                pieces.append(contentsOf: windowed(lines, range: start..<end))
                continue
            }
            if currentStart == nil { currentStart = start }
            currentText += (currentText.isEmpty ? "" : "\n") + lines[start..<end].joined(separator: "\n")
            if currentText.count >= minSize { emit(endLine: end) }
        }
        emit(endLine: lines.count)
        return pieces
    }

    private static func isTopLevelDeclaration(_ line: Substring) -> Bool {
        guard let first = line.first, !first.isWhitespace else { return false }
        for token in line.split(separator: " ").prefix(6) {
            let t = String(token)
            if declarationKeywords.contains(t) { return true }
            if t.hasPrefix("@") || modifierTokens.contains(t) { continue }
            return false
        }
        return false
    }

    private static func windowed(_ lines: [Substring], range: Range<Int>) -> [Piece] {
        var pieces: [Piece] = []
        var start = range.lowerBound
        while start < range.upperBound {
            let end = min(start + windowLines, range.upperBound)
            let text = lines[start..<end].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append((text, "lines \(start + 1)–\(end)")) }
            if end == range.upperBound { break }
            start = end - windowOverlap
        }
        return pieces
    }

    // MARK: PDF

    /// PDFKit text extraction per page (context "page N"), then the same
    /// paragraph packing as Markdown bodies.
    public static func pdf(at url: URL) -> [Piece] {
        guard let document = PDFDocument(url: url) else { return [] }
        var pieces: [Piece] = []
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string else { continue }
            for part in splitSection(text) {
                pieces.append((part, "page \(index + 1)"))
            }
        }
        return pieces
    }

    // MARK: Plain text

    public static func plainText(_ content: String) -> [Piece] {
        splitSection(content).map { ($0, nil) }
    }

    // MARK: Shared

    /// Greedy paragraph packing to ~targetSize; never emits a piece below
    /// minSize unless the whole section is that small. Paragraphs beyond
    /// 2×targetSize (common in extracted PDF text) are hard-split at
    /// whitespace first.
    static func splitSection(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > targetSize else { return [trimmed] }

        var units: [String] = []
        for paragraph in trimmed.components(separatedBy: "\n\n") {
            let p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            if p.count > 2 * targetSize {
                units.append(contentsOf: hardSplit(p))
            } else {
                units.append(p)
            }
        }

        var chunks: [String] = []
        var current = ""
        for unit in units {
            if !current.isEmpty, current.count + unit.count + 2 > targetSize, current.count >= minSize {
                chunks.append(current)
                current = unit
            } else {
                current = current.isEmpty ? unit : current + "\n\n" + unit
            }
        }
        if !current.isEmpty {
            if current.count < minSize, var last = chunks.popLast() {
                last += "\n\n" + current
                chunks.append(last)
            } else {
                chunks.append(current)
            }
        }
        return chunks
    }

    private static func hardSplit(_ paragraph: String) -> [String] {
        var result: [String] = []
        var rest = Substring(paragraph)
        while rest.count > targetSize {
            let cap = rest.index(rest.startIndex, offsetBy: targetSize)
            let cut = rest[..<cap].lastIndex(where: \.isWhitespace) ?? cap
            let piece = rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            rest = rest[cut...].drop(while: \.isWhitespace)
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
