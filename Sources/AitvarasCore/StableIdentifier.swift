import CryptoKit
import Foundation

/// Produces deterministic, one-way identifiers for persisted local state.
///
/// Swift's `hashValue` is deliberately randomized between processes and must
/// not be used for identifiers that survive an app restart. Separating fields
/// with their byte lengths also prevents ambiguous concatenations.
public enum StableIdentifier {
    public static func digest(_ components: [String]) -> String {
        var data = Data()
        for component in components {
            let bytes = Data(component.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func short(_ components: [String], length: Int = 20) -> String {
        String(digest(components).prefix(max(1, min(length, 64))))
    }
}

/// The archiver's transcript identity: its "already archived" marker and the
/// subject of an archiving job key. Shared so fixtures and retries agree.
public enum TranscriptFingerprint {
    public static func of(_ transcript: [ChatMessage]) -> String {
        let joined = transcript.map { "\($0.role.rawValue):\($0.content)" }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
