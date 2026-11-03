import Foundation

/// Explicitly downloaded, local-only second-pass recognizers. These are not
/// chat models and never change the recognizer used during live capture.
public enum CaptureRefinementModel: String, CaseIterable, Sendable, Identifiable, Codable {
    case qwen3ASR17B8bit
    case whisperLargeV3Turbo

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .qwen3ASR17B8bit: "Qwen3-ASR 1.7B · 8-bit"
        case .whisperLargeV3Turbo: "Whisper large-v3-turbo · FP16"
        }
    }
    public var repository: String {
        switch self {
        case .qwen3ASR17B8bit: "mlx-community/Qwen3-ASR-1.7B-8bit"
        case .whisperLargeV3Turbo: "openai/whisper-large-v3-turbo"
        }
    }
    public var revision: String {
        switch self {
        case .qwen3ASR17B8bit: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55"
        case .whisperLargeV3Turbo: "41f01f3fe87f28c78e2fbf8b568835947dd65ed9"
        }
    }
    public var directoryName: String {
        switch self {
        case .qwen3ASR17B8bit: "Transcription/Qwen3-ASR-1.7B-8bit"
        case .whisperLargeV3Turbo: "Transcription/Whisper-large-v3-turbo"
        }
    }
    public var expectedBytes: Int64 {
        switch self {
        case .qwen3ASR17B8bit: 2_468_000_000
        case .whisperLargeV3Turbo: 1_623_000_000
        }
    }
    /// Exact sizes from the pinned repositories. Requiring complete local
    /// tokenizer assets prevents Whisper's upstream network fallback.
    public var requiredFiles: [String: Int64] {
        switch self {
        case .qwen3ASR17B8bit:
            ["config.json": 7_188, "model.safetensors": 2_463_307_541,
             "tokenizer_config.json": 12_487, "vocab.json": 2_776_833,
             "merges.txt": 1_671_853]
        case .whisperLargeV3Turbo:
            ["config.json": 1_256, "model.safetensors": 1_617_824_864,
             "generation_config.json": 3_772, "tokenizer.json": 2_710_337,
             "tokenizer_config.json": 282_843, "added_tokens.json": 34_648,
             "special_tokens_map.json": 2_186, "normalizer.json": 52_666,
             "vocab.json": 1_036_558, "merges.txt": 493_869]
        }
    }

    public func directory(in modelsRoot: URL = AitvarasPaths.modelsDirectory) -> URL {
        modelsRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    public func isInstalled(in modelsRoot: URL = AitvarasPaths.modelsDirectory) -> Bool {
        let folder = directory(in: modelsRoot)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        guard let directoryValues = try? folder.resourceValues(forKeys: keys),
              directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { return false }
        for (name, size) in requiredFiles {
            guard let values = try? folder.appendingPathComponent(name).resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? 0) == size else { return false }
        }
        // The loader reads all safetensors and optional tokenizer files. Reject
        // links or unexpected weights rather than following arbitrary paths.
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return false }
        for file in entries where file.pathExtension == "safetensors" || ["json", "txt", "jinja"].contains(file.pathExtension) {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return false }
            if file.pathExtension == "safetensors", file.lastPathComponent != "model.safetensors" { return false }
        }
        return true
    }
}

/// A candidate is deliberately separate from the live transcript and summary.
/// Times identify source audio windows, not word-level forced alignment.
public struct CaptureRefinementCandidate: Sendable, Equatable, Identifiable, Codable {
    public struct Segment: Sendable, Equatable, Codable {
        public let source: CaptureAudioSource
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String
        public init(source: CaptureAudioSource, start: TimeInterval, end: TimeInterval, text: String) {
            self.source = source; self.start = start; self.end = end; self.text = text
        }
    }
    public let id: UUID
    public let archiveID: UUID
    public let model: CaptureRefinementModel
    public let createdAt: Date
    public let segments: [Segment]
    public init(id: UUID = UUID(), archiveID: UUID, model: CaptureRefinementModel,
                createdAt: Date = .now, segments: [Segment]) {
        self.id = id; self.archiveID = archiveID; self.model = model
        self.createdAt = createdAt; self.segments = segments
    }
    public func rendered() -> String {
        segments.sorted { $0.start < $1.start }.map { segment in
            let second = max(0, Int(segment.start))
            let stamp = String(format: "%02d:%02d:%02d", second / 3600, (second % 3600) / 60, second % 60)
            let source = segment.source == .microphone ? "Mikrofon" : "Systemaudio"
            return "[\(stamp)] [\(source)] \(segment.text)"
        }.joined(separator: "\n")
    }

    public var document: String {
        "# Local second-pass transcript\n\nModel: \(model.displayName)\n\n"
        + "Timestamps identify audio windows (up to 30 seconds), not word-level alignment. "
        + "Source labels identify audio inputs, not speakers. The original live transcript is unchanged.\n\n"
        + rendered()
    }
}

public struct CaptureRefinementProgress: Sendable, Equatable {
    public let completedAudioSeconds: TimeInterval
    public let totalAudioSeconds: TimeInterval
    public var fraction: Double {
        guard totalAudioSeconds.isFinite, completedAudioSeconds.isFinite, totalAudioSeconds > 0 else { return 0 }
        return max(0, min(1, completedAudioSeconds / totalAudioSeconds))
    }
    public init(completedAudioSeconds: TimeInterval, totalAudioSeconds: TimeInterval) {
        self.completedAudioSeconds = completedAudioSeconds; self.totalAudioSeconds = totalAudioSeconds
    }
}
