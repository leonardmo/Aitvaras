import AppKit

/// Lightweight lexical coloring for explicitly tagged, bounded code blocks.
enum ChatCodeHighlighting {
    private enum Language {
        case swift, python, javascript, typescript, shell, json

        init?(tag: String) {
            switch tag.lowercased() {
            case "swift": self = .swift
            case "python", "py", "python3": self = .python
            case "javascript", "js", "jsx": self = .javascript
            case "typescript", "ts", "tsx": self = .typescript
            case "bash", "sh", "shell", "zsh": self = .shell
            case "json": self = .json
            default: return nil
            }
        }

        var keywords: Set<String> {
            switch self {
            case .swift: Self.swiftKeywords
            case .python: Self.pythonKeywords
            case .javascript: Self.javascriptKeywords
            case .typescript: Self.typescriptKeywords
            case .shell: Self.shellKeywords
            case .json: ["true", "false", "null"]
            }
        }

        var tokens: NSRegularExpression {
            switch self {
            case .swift: Self.swiftTokens
            case .javascript, .typescript: Self.javascriptTokens
            case .python: Self.pythonTokens
            case .shell: Self.shellTokens
            case .json: Self.jsonTokens
            }
        }

        private static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

        private static let swiftKeywords = words("actor any as async await break case catch class continue default defer deinit do else enum extension false fileprivate for func guard if import in init inout internal is let nil nonisolated open operator private protocol public repeat return self some static struct subscript super switch throw throws true try typealias var where while")
        private static let pythonKeywords = words("and as assert async await break case class continue def del elif else except False finally for from global if import in is lambda match None nonlocal not or pass raise return True try while with yield")
        private static let javascriptKeywords = words("async await break case catch class const continue debugger default delete do else export extends false finally for function if import in instanceof let new null return super switch this throw true try typeof undefined var void while with yield")
        private static let typescriptKeywords = javascriptKeywords.union(words("abstract any as asserts declare enum implements infer interface is keyof module namespace never number private protected public readonly satisfies string type unknown"))
        private static let shellKeywords = words("case do done elif else esac export fi for function if in local return select then until while")

        private static let strings = #""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#
        private static let multilineStrings = #"(?s:"{3}.*?"{3}|'{3}.*?'{3})|"# + strings
        private static let templates = #"`(?:\\[\s\S]|[^`\\])*`|"# + strings

        private static func tokenizer(comments: String, strings: String) -> NSRegularExpression {
            // The groups identify comments, strings, numbers and words. Matching
            // them together keeps comment markers inside strings literal.
            try! NSRegularExpression(pattern: #"("# + comments + #")|("# + strings
                + #")|(\b(?:0[xob][\da-fA-F_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)(?![\p{L}\d_]))|([\p{L}_][\p{L}\d_]*)"#
            )
        }

        private static let slashComments = #"//[^\n]*|/\*[\s\S]*?(?:\*/|\z)"#
        private static let swiftTokens = tokenizer(comments: slashComments, strings: multilineStrings)
        private static let javascriptTokens = tokenizer(comments: slashComments, strings: templates)
        private static let pythonTokens = tokenizer(comments: #"#[^\n]*"#, strings: multilineStrings)
        private static let shellTokens = tokenizer(comments: #"(?<!\S)#[^\n]*"#, strings: templates)
        private static let jsonTokens = tokenizer(comments: #"(?!)"#, strings: strings)
    }

    @MainActor static func apply(to output: NSMutableAttributedString, code: String, start: Int,
                                 tag: String, appearance: NSAppearance.Name?) {
        guard code.utf16.count <= 32_768, let language = Language(tag: tag) else { return }
        let range = NSRange(code.startIndex..., in: code)
        let text = code as NSString
        let dark = appearance == .darkAqua
        let keywords = language.keywords
        let colors: [NSColor] = [
            .secondaryLabelColor,
            dark ? NSColor(srgbRed: 0.65, green: 0.83, blue: 0.53, alpha: 1) : NSColor(srgbRed: 0.15, green: 0.38, blue: 0.17, alpha: 1),
            dark ? NSColor(srgbRed: 0.58, green: 0.79, blue: 1, alpha: 1) : NSColor(srgbRed: 0.12, green: 0.32, blue: 0.62, alpha: 1),
            dark ? NSColor(srgbRed: 0.84, green: 0.66, blue: 1, alpha: 1) : NSColor(srgbRed: 0.43, green: 0.20, blue: 0.59, alpha: 1),
        ]
        for match in language.tokens.matches(in: code, range: range) {
            guard let group = (1...4).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
            if group == 4, !keywords.contains(text.substring(with: match.range)) { continue }
            output.addAttribute(.foregroundColor, value: colors[group - 1],
                                range: NSRange(location: start + match.range.location, length: match.range.length))
        }
    }
}
