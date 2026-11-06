import Foundation

/// Shared sequencing for a locked, one-tunnel replacement. Preparation must be
/// read-only. Never stop the current tunnel until validation/resolution succeeds.
public enum ConfigurationReplacement {
    public static func run<T>(prepare: () throws -> Void, apply: () throws -> T,
                              restore: () throws -> Void) throws -> T {
        try prepare()
        do { return try apply() }
        catch {
            do { try restore() }
            catch { throw DeckError.message("The update failed and recovery could not be completed. Check this tunnel before reconnecting; other tunnels were not changed.") }
            throw DeckError.message("The update failed. The previous configuration and connection state were restored; other tunnels were not changed.")
        }
    }
}
