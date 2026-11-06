import LocalAuthentication
import TunnelDeckCore

/// Protects interactive secret disclosure. Routine status/on-demand work never
/// waits for Touch ID. This is separate from Keychain's own application ACL.
@MainActor
enum UserAuthentication {
    static func authorize(_ reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw DeckError.message("Set up Touch ID or a Mac login password to access tunnel configurations.")
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw DeckError.message("Authentication was not completed. No changes were made.")
            }
        } catch {
            throw DeckError.message("Authentication was cancelled or unsuccessful. No changes were made.")
        }
    }
}
