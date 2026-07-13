import Foundation
import AitvarasCore

/// Append-only diagnostic log for the voice pipeline —
/// `<state dir>/logs/voice.log`. Cheap enough to stay on permanently;
/// exists because mic paths can't be exercised from CLI test runners (TCC)
/// and silent failures here are costly.
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

    public static func log(_ message: String) {
        let line = "\(formatter.string(from: .now)) \(message)\n"
        queue.async {
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
        queue.async {
            try? Data("=== \(header) — \(Date.now) ===\n".utf8).write(to: url)
        }
    }
}
