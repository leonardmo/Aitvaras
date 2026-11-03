import Foundation
import Security
import AitvarasCore

/// All secrets (API keys, tokens, cookies) live here — never in the
/// database or on disk (hard rule, see CLAUDE.md).
public struct KeychainStore: Sendable {
    public static let defaultService = "app.aitvaras.secrets"
    public let service: String

    /// The regular app keeps its historic service name so existing secrets
    /// remain available. An isolated state profile gets a separate Keychain
    /// service, preventing demos and test profiles from reading or replacing
    /// credentials belonging to the user's normal profile.
    public init(service: String? = nil) {
        self.service = service ?? Self.serviceName(
            stateDirectoryOverride: ProcessInfo.processInfo.environment[
                AitvarasPaths.stateDirEnvVar])
    }

    public static func serviceName(
        baseService: String = defaultService,
        stateDirectoryOverride: String?
    ) -> String {
        guard let stateDirectoryOverride, !stateDirectoryOverride.isEmpty else {
            return baseService
        }
        return baseService + ".profile."
            + AitvarasPreferences.profileIdentifier(
                forStateDirectory: stateDirectoryOverride)
    }

    public enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            if case .unexpectedStatus(let s) = self {
                return "Keychain error \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "unknown")"
            }
            return nil
        }
    }

    public func set(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func get(_ key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// List stored key names (never values) — for the connector settings UI.
    public func allKeys() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let array = items as? [[String: Any]] else {
            throw KeychainError.unexpectedStatus(status)
        }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
