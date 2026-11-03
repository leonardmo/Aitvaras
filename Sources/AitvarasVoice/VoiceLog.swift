import Foundation
import AitvarasCore

/// Metadata-only diagnostic log for the voice pipeline —
/// `<state dir>/logs/voice.log`. It deliberately never receives utterance
/// text, audio, device names, credentials, or absolute home/state paths.
/// Mic paths cannot be exercised from CLI test runners (TCC), so bounded
/// health metadata remains useful for diagnosing silent failures.
public enum VoiceLog {
    public static let url: URL = {
        AitvarasPaths.logsDirectory.appendingPathComponent("voice.log")
    }()

    private static let queue = DispatchQueue(label: "aitvaras.voicelog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let maximumBytes: UInt64 = 512 * 1_024
    private static let legacyAudioCleanup: Void = {
        // Builds before the privacy fix wrote a short analyzer-input WAV
        // beside this log. Delete that legacy artifact once on launch/use.
        var roots = [AitvarasPaths.stateDirectory]
        if !AitvarasPaths.isIsolated { roots.append(AitvarasPaths.legacyStateDirectory) }
        for root in roots {
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent("logs/analyzer-input.wav"))
        }
    }()

    public static func removeLegacySensitiveArtifacts() {
        _ = legacyAudioCleanup
    }

    public static func log(_ message: String) {
        removeLegacySensitiveArtifacts()
        let safeMessage = sanitized(message)
        queue.async {
            let line = "\(formatter.string(from: .now)) \(safeMessage)\n"
            if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                > maximumBytes {
                try? Data("=== metadata log rotated ===\n".utf8).write(to: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Truncate at session start so each attempt reads cleanly.
    public static func reset(_ header: String) {
        removeLegacySensitiveArtifacts()
        queue.async {
            try? Data("=== \(sanitized(header)) — \(Date.now) ===\n".utf8).write(to: url)
        }
    }

    static func sanitized(_ message: String) -> String {
        var value = String(message.prefix(2_000))
        let environment = ProcessInfo.processInfo.environment
        let statePath = environment[AitvarasPaths.stateDirEnvVar]
            ?? AitvarasPaths.defaultStateDirectory.path
        let paths = [
            FileManager.default.homeDirectoryForCurrentUser.path,
            statePath
        ].filter { !$0.isEmpty }
        for path in paths {
            value = value.replacingOccurrences(of: path, with: "<private-path>")
        }
        return value.replacingOccurrences(
            of: #"(?i)(token|secret|password|authorization)\s*[:=]\s*\S+"#,
            with: "$1=<redacted>", options: .regularExpression)
    }
}
