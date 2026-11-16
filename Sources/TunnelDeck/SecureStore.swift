import Foundation
import Security
import TunnelDeckCore

enum SecureStore {
    private static let service = "codes.savvy.tunneldeck.configuration"
    private static let interactionLock = NSLock()

    enum AccessStatus: Sendable {
        case accessible, authorizationRequired, missing, unavailable
    }

    // The login Keychain does not consistently honor kSecUseAuthenticationUI
    // for legacy ACLs. Suppress its dialogs explicitly as well. The setting is
    // process-wide, so serialize our calls and always restore its prior value.
    // Only the user-requested repair read may permit Keychain dialogs.
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
        let reason: String
        switch status {
        case errSecAuthFailed:
            reason = "Keychain did not authorize this app to access the saved configuration. An older TunnelDeck build may still own its permissions; this does not necessarily mean your password is wrong."
        case errSecInteractionNotAllowed, errSecInteractionRequired:
            reason = "Keychain requires authorization or is locked."
        case errSecItemNotFound:
            return DeckError.message("This tunnel's configuration was not found in Keychain. Access repair cannot restore a missing entry; import the original configuration to recover it.")
        default:
            return DeckError.message("Cannot access this configuration in Keychain (\(status)). Try again after checking Keychain availability. Permission repair is offered only when authorization is required.")
        }
        return DeckError.message("\(reason) Select the tunnel and choose Repair Keychain Access…. Routine operations never open permission prompts.")
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
    /// A read lets securityd authorize and persist both app trust and its signing
    /// partition through Always Allow. Direct ACL writes cannot do that reliably.
    static func repairAccess(_ id: UUID) throws {
        try withInteraction(true) {
            let (status, result) = copySecret(id)
            guard status == errSecSuccess, result is Data else {
                if status == errSecUserCanceled { throw DeckError.message("Keychain authorization was cancelled. No automatic retry was made.") }
                throw DeckError.message("macOS did not authorize this configuration (\(status)). The saved configuration was not deleted or replaced. No automatic retry was made.")
            }
        }
        try withInteraction {
            let (status, result) = copySecret(id)
            guard status == errSecSuccess, result is Data else {
                throw DeckError.message("macOS allowed access once but did not retain permission. During Repair Keychain Access, choose Always Allow rather than Allow. No automatic retry was made and the configuration was preserved.")
            }
        }
    }

    static func read(_ id: UUID) throws -> String {
        try withInteraction { try readWithoutInteraction(id) }
    }

    static func accessStatus(_ id: UUID) throws -> AccessStatus {
        try withInteraction {
            let (status, result) = copySecret(id)
            switch status {
            case errSecSuccess: return result is Data ? .accessible : .unavailable
            case errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired: return .authorizationRequired
            case errSecItemNotFound: return .missing
            default: return .unavailable
            }
        }
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
