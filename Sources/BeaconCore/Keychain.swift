import Foundation
import Security

/// Secrets referenced by snippets/workflows as `{secret:NAME}` live here, never in SQLite
/// and never in an export file.
public enum Keychain {
    public static let service = "com.beacon.launcher.secrets"

    public enum Failure: Error, CustomStringConvertible {
        case status(OSStatus)
        public var description: String {
            "Keychain error \(self)"
        }
    }

    public static func set(_ value: String, for name: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    public static func get(_ name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ name: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ] as CFDictionary)
    }

    public static func names() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let entries = item as? [[String: Any]] else { return [] }
        return entries.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}
