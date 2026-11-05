import Foundation

public enum WiFiRule: String, Codable, CaseIterable, Sendable {
    case any, only, except
    public var title: String {
        switch self { case .any: return "Any network"; case .only: return "Only these networks"; case .except: return "Except these networks" }
    }
}

public struct OnDemandSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var wiFi: Bool
    public var ethernet: Bool
    public var wiFiRule: WiFiRule
    public var ssids: [String]

    public init(enabled: Bool = false, wiFi: Bool = true, ethernet: Bool = false, wiFiRule: WiFiRule = .any, ssids: [String] = []) {
        self.enabled = enabled
        self.wiFi = wiFi
        self.ethernet = ethernet
        self.wiFiRule = wiFiRule
        self.ssids = ssids
    }

    public func validate() throws {
        guard !enabled || wiFi || ethernet else { throw DeckError.message("Choose Wi-Fi or Ethernet for on-demand activation.") }
        guard ssids.count <= 64, ssids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw DeckError.message("Enter up to 64 Wi-Fi network names, each at most 32 bytes, one per line.")
        }
        guard !enabled || !wiFi || wiFiRule == .any || !ssids.isEmpty else {
            throw DeckError.message("Enter at least one Wi-Fi network name for this rule.")
        }
    }

    public func matches(_ network: NetworkSnapshot) -> Bool {
        guard enabled, network.reachable else { return false }
        if ethernet && network.ethernet { return true }
        guard wiFi && network.wiFi else { return false }
        if wiFiRule == .any { return true }
        // Never treat an unavailable SSID as a match, including exclusion rules.
        // Modern macOS may withhold SSIDs from a background process.
        guard let ssid = network.ssid, !ssid.isEmpty else { return false }
        switch wiFiRule {
        case .any: return true
        case .only: return ssids.contains(ssid)
        case .except: return !ssids.contains(ssid)
        }
    }

    public var summary: String {
        guard enabled else { return "Off" }
        var parts: [String] = []
        if wiFi { parts.append(wiFiRule == .any ? "Wi-Fi (any network)" : "Wi-Fi (\(wiFiRule == .only ? "selected" : "excluding selected") networks)") }
        if ethernet { parts.append("Ethernet") }
        return parts.joined(separator: ", ")
    }
}

public struct NetworkSnapshot: Equatable, Sendable {
    public var reachable: Bool
    public var wiFi: Bool
    public var ethernet: Bool
    public var ssid: String?
    public var signature: String
    public init(reachable: Bool, wiFi: Bool, ethernet: Bool, ssid: String? = nil, signature: String = "") {
        self.reachable = reachable; self.wiFi = wiFi; self.ethernet = ethernet
        self.ssid = ssid; self.signature = signature
    }
}

public struct OnDemandRecord: Codable, Sendable {
    public let id: UUID
    public let owner: UInt32
    public let configuration: String
    public let settings: OnDemandSettings
    public init(id: UUID, owner: UInt32, configuration: String, settings: OnDemandSettings) {
        self.id = id; self.owner = owner; self.configuration = configuration; self.settings = settings
    }
}

/// No keys/configuration are included in publicly readable status.
public struct OnDemandStatus: Codable, Equatable, Sendable {
    public let id: UUID
    public let owner: UInt32
    public let settings: OnDemandSettings
    public let message: String
    public init(id: UUID, owner: UInt32, settings: OnDemandSettings, message: String = "Waiting for a matching network.") {
        self.id = id; self.owner = owner; self.settings = settings; self.message = message
    }
    public static let root = "/Library/Application Support/TunnelDeck/OnDemand"
    public static func statusPath(owner: UInt32, id: UUID) -> String {
        "\(root)/\(owner)/\(TunnelProfile.interfaceName(for: id)).status.json"
    }
}
