import Foundation

/// Accumulates a live capture session (MASTERPLAN Part IV / F12): timestamped
/// transcript lines from up to two audio channels plus deduplicated screen
/// text. Pure value logic — the ScreenCaptureKit/Vision plumbing lives in the
/// app; this part is fully testable.
///
/// Raw audio and frames are NEVER part of this type: what goes in is already
/// text. A separate, explicitly enabled audio archive can retain source audio;
/// this value and the live recognizer never own or save that audio.
public struct CaptureTranscript: Sendable, Equatable {
    /// Audio-source attribution is not diarization. Do not identify the user
    /// merely because speech arrived through a microphone.
    public enum Channel: String, Sendable, Hashable {
        case microphone = "Mikrofon"
        case systemAudio = "Systemaudio"
        // Retained for callers and historical transcript compatibility.
        case me = "Ich"
        case others = "Andere"
    }

    public struct Line: Sendable, Equatable {
        public var at: Date
        public var channel: Channel
        public var text: String
    }

    public struct ScreenNote: Sendable, Equatable {
        public var at: Date
        public var text: String
    }

    public private(set) var startedAt: Date
    public private(set) var lines: [Line] = []
    public private(set) var screenNotes: [ScreenNote] = []
    public private(set) var warnings: [String] = []
    /// OCR frames that arrived but were near-duplicates of the last note.
    public private(set) var duplicateFramesSkipped = 0

    /// At or above this similarity to the previous note, a frame counts as
    /// the same slide re-rendered (OCR jitter); below it, new content.
    /// 0.75 tolerates a couple of misread words even on short slides —
    /// genuinely new slides score near zero, so the margin is wide.
    static let duplicateSimilarity = 0.75
    /// OCR noise gate: frames with less text than this are ignored.
    static let minimumNoteLength = 12

    public init(startedAt: Date = .now) {
        self.startedAt = startedAt
    }

    // MARK: Audio lines

    public mutating func append(channel: Channel, text: String, at: Date = .now) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(Line(at: at, channel: channel, text: trimmed))
    }

    public mutating func addWarning(_ warning: String) {
        guard !warnings.contains(warning) else { return }
        warnings.append(warning)
    }

    /// Preserve provisional words without falsely presenting them as final.
    /// Used on checkpoints and only retained at stop if finalization failed.
    public func includingUnfinalized(_ tails: [Channel: String], at: Date = .now) -> Self {
        var copy = self
        for channel in [Channel.microphone, .systemAudio] {
            guard let text = tails[channel]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            copy.append(channel: channel, text: "[Unfinalized speech] " + text, at: at)
        }
        return copy
    }

    // MARK: Screen notes (slide-change detection)

    /// Append OCR text if it differs enough from the previous note —
    /// otherwise it's the same slide re-rendered and gets skipped.
    @discardableResult
    public mutating func appendScreenNote(_ text: String, at: Date = .now) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumNoteLength else { return false }
        if let last = screenNotes.last,
           Self.similarity(last.text, trimmed) >= Self.duplicateSimilarity {
            duplicateFramesSkipped += 1
            return false
        }
        screenNotes.append(ScreenNote(at: at, text: trimmed))
        return true
    }

    /// Word-set Jaccard similarity — robust against OCR jitter (a few
    /// misread words on an unchanged slide) while catching real changes.
    static func similarity(_ a: String, _ b: String) -> Double {
        let wordsA = wordSet(a)
        let wordsB = wordSet(b)
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 1 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return union == 0 ? 1 : Double(intersection) / Double(union)
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count > 1 }
            .map(String.init))
    }

    // MARK: Rendering

    public var isEmpty: Bool { lines.isEmpty && screenNotes.isEmpty }

    /// Merged chronological rendering — the persisted transcript format.
    public func rendered() -> String {
        enum Entry { case line(Line); case note(ScreenNote) }
        let merged: [(Date, Entry)] =
            lines.map { ($0.at, Entry.line($0)) } +
            screenNotes.map { ($0.at, Entry.note($0)) }

        let content = merged.sorted { $0.0 < $1.0 }.map { at, entry in
            let stamp = Self.offset(from: startedAt, to: at)
            switch entry {
            case .line(let line):
                return "[\(stamp)] [\(line.channel.rawValue)] \(line.text)"
            case .note(let note):
                return "[\(stamp)] [Bildschirm]\n\(note.text)"
            }
        }.joined(separator: "\n")
        let notices = warnings.map { "> Capture warning: " + $0 }.joined(separator: "\n")
        return notices.isEmpty ? content : notices + "\n\n" + content
    }

    static func offset(from start: Date, to date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
