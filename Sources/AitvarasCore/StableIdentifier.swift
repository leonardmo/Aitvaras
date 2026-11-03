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
