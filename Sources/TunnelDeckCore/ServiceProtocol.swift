import Foundation
import Security

@objc public protocol TunnelServiceProtocol {
    func perform(_ action: String, request: Data, reply: @escaping (Data) -> Void)
}

public enum ServiceIdentity {
    public static let name = "codes.savvy.tunneldeck.service"
    public static let version = 4
    public static let base = "/Library/Application Support/TunnelDeck"
    public static let binary = base + "/TunnelDeckHelper"
    public static let clients = base + "/Clients"

    /// Ad-hoc local builds are pinned to a specific executable, not merely a
    /// bundle identifier that another local process could claim. Rebuilds need
    /// an approved service update to enroll the new executable identity.
    public static func requirement(for executable: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
            throw DeckError.message("The app or helper has an invalid code signature. Rebuild TunnelDeck before installing its service.")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw DeckError.message("Cannot read the executable's signing identity.")
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw DeckError.message("Cannot read the executable's signing requirement.")
        }
        return text as String
    }
}

public struct ServiceEnrollment: Codable {
    public let owner: UInt32
    public let requirement: String
    public let version: Int
    public init(owner: UInt32, requirement: String, version: Int = ServiceIdentity.version) {
        self.owner = owner; self.requirement = requirement; self.version = version
    }
}
