import Foundation
import Security
import TunnelDeckCore

enum SecureStore {
    private static let service = "codes.savvy.tunneldeck.configuration"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    // Explicitly trust this app only, never all applications. A stable signing
    // identity is still required for this ACL to survive future app rebuilds.
    private static func appAccess() throws -> SecAccess {
        var application: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &application) == errSecSuccess,
              let application else { throw DeckError.message("Cannot identify this app for Keychain access.") }
        var access: SecAccess?
        guard SecAccessCreate("TunnelDeck configuration" as CFString, [application] as CFArray, &access) == errSecSuccess,
              let access else { throw DeckError.message("Cannot create app-specific Keychain permissions.") }
        return access
    }

    private static let accessVersion = "TunnelDeck app-only access v1"

    private static func migrateAccessIfNeeded(_ id: UUID) throws {
        var attributes = query(id)
        attributes[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess else { throw DeckError.message("Cannot check Keychain permissions (\(status)).") }
        if (result as? [String: Any])?[kSecAttrComment as String] as? String == accessVersion { return }
        // Update in place only after a successful read; the configuration is
        // never deleted/re-added and remains intact if macOS denies migration.
        let update: [String: Any] = [kSecAttrAccess as String: try appAccess(), kSecAttrComment as String: accessVersion]
        guard SecItemUpdate(query(id) as CFDictionary, update as CFDictionary) == errSecSuccess else {
            throw DeckError.message("Keychain permission update was not approved. The saved configuration was preserved.")
        }
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
        try migrateAccessIfNeeded(id)
        return text
    }

    static func save(_ text: String, id: UUID) throws {
        let data = Data(text.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(id)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            attributes[kSecAttrAccess as String] = try appAccess()
            attributes[kSecAttrComment as String] = accessVersion
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
