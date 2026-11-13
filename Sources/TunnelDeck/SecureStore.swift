import Foundation
import Security
import TunnelDeckCore

enum SecureStore {
    private static let service = "codes.savvy.tunneldeck.configuration"
    private static let interactionLock = NSLock()

    // The login Keychain does not consistently honor kSecUseAuthenticationUI
    // for legacy ACLs. Suppress its dialogs explicitly as well. The setting is
    // process-wide, so serialize our calls and always restore its prior value.
    // Only the explicit repair action may permit Keychain interaction.
    private static func withInteraction<T>(_ allowed: Bool = false, _ body: () throws -> T) throws -> T {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else {
            throw DeckError.message("Cannot configure safe Keychain access. No operation was attempted.")
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try body()
    }

    private static func accessError(_ status: OSStatus) -> DeckError {
        DeckError.message("Cannot access this configuration in Keychain (\(status)). Unlock your login Keychain if needed, then select the tunnel and choose Repair Keychain Access…. No automatic permission prompts were opened.")
    }

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

    /// User-initiated permission repair, never invoked by read/save/connect.
    /// Updates only the ACL in place, not the secret or its persistent identity.
    static func repairAccess(_ id: UUID) throws {
        try withInteraction(true) {
            var attributes = query(id)
            attributes[kSecReturnRef as String] = true
            attributes[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(attributes as CFDictionary, &result)
            guard status == errSecSuccess, let result else { throw accessError(status) }
            let item = result as! SecKeychainItem
            let update = SecKeychainItemSetAccess(item, try appAccess())
            guard update == errSecSuccess else {
                throw DeckError.message("Keychain access repair was cancelled or failed (\(update)). The configuration was not deleted or replaced.")
            }
        }
    }

    static func read(_ id: UUID) throws -> String {
        try withInteraction { try readWithoutInteraction(id) }
    }

    private static func readWithoutInteraction(_ id: UUID) throws -> String {
        let (status, result) = copySecret(id)
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw accessError(status)
        }
        return text
    }

    private static func copySecret(_ id: UUID) -> (OSStatus, CFTypeRef?) {
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        return (status, result)
    }

    static func save(_ text: String, id: UUID, replacing expectedText: String? = nil) throws {
        try withInteraction {
            let data = Data(text.utf8)
            // Legacy Keychain updates can succeed even when decrypt access is
            // denied. Verify access silently before replacing an existing item.
            let (existing, result) = copySecret(id)
            guard existing == errSecSuccess || existing == errSecItemNotFound else { throw accessError(existing) }
            if let expectedText {
                guard existing == errSecSuccess, let data = result as? Data,
                      String(data: data, encoding: .utf8) == expectedText else {
                    throw DeckError.message("This configuration changed while the editor was open. Close and reopen the editor before saving; no changes were applied.")
                }
            }
            let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var attributes = query(id)
                attributes[kSecValueData as String] = data
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                attributes[kSecAttrAccess as String] = try appAccess()
                let added = SecItemAdd(attributes as CFDictionary, nil)
                guard added == errSecSuccess else { throw accessError(added) }
            } else if status != errSecSuccess { throw accessError(status) }
        }
    }

    static func delete(_ id: UUID) throws {
        try withInteraction {
            let (existing, _) = copySecret(id)
            guard existing == errSecSuccess || existing == errSecItemNotFound else { throw accessError(existing) }
            let status = SecItemDelete(query(id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw accessError(status)
            }
        }
    }
}
