import Foundation
import Security
import TunnelDeckCore

enum SecureStore {
    private static let service = "codes.savvy.tunneldeck.configuration"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func read(_ id: UUID) throws -> String {
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw DeckError.message("Cannot read this configuration from Keychain. Check Keychain access permissions (\(status)).")
        }
        return text
    }

    static func save(_ text: String, id: UUID) throws {
        let data = Data(text.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(id)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw DeckError.message("Cannot save configuration to Keychain (\(added)).") }
        } else if status != errSecSuccess { throw DeckError.message("Cannot update configuration in Keychain (\(status)).") }
    }

    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeckError.message("Cannot remove this configuration from Keychain (\(status)).")
        }
    }
}
