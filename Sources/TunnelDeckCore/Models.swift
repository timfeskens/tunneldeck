import Foundation

public struct TunnelProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var addresses: [String]
    public var routes: [String]
    public var endpoints: [String]
    public var configuredDNS: [String]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, configuration: WireGuardConfiguration) {
        self.id = id
        self.name = name
        addresses = configuration.addresses.map(\.description)
        routes = configuration.routes.map(\.description)
        endpoints = configuration.peers.compactMap(\.endpoint)
        configuredDNS = configuration.dns
        createdAt = Date()
    }
    // Exactly 15 characters, accepted by Darwin wg-quick. UUID collision is also
    // checked against the full ID in root-owned metadata before an operation.
    public var interfaceName: String { Self.interfaceName(for: id) }
    public static func interfaceName(for id: UUID) -> String {
        "td" + id.uuidString.replacingOccurrences(of: "-", with: "").prefix(13).lowercased()
    }
}

public struct HelperRequest: Codable, Sendable {
    public let id: UUID
    public let configuration: String?
    public let onDemand: OnDemandSettings?
    public let ids: [UUID]?
    public init(id: UUID, configuration: String? = nil, onDemand: OnDemandSettings? = nil, ids: [UUID]? = nil) {
        self.id = id
        self.configuration = configuration
        self.onDemand = onDemand
        self.ids = ids
    }
}

public struct PeerStatistics: Codable, Sendable {
    public var endpoint: String
    public var latestHandshake: Int64
    public var received: UInt64
    public var sent: UInt64
    public init(endpoint: String, latestHandshake: Int64, received: UInt64, sent: UInt64) {
        self.endpoint = endpoint
        self.latestHandshake = latestHandshake
        self.received = received
        self.sent = sent
    }
}

public struct TunnelRuntime: Codable, Sendable {
    public let id: UUID
    public let owner: UInt32
    public let interface: String
    public let connectedAt: Date
    public var peers: [PeerStatistics]
    public var sampledAt: Date?
    public var routeHealth: RouteHealth?
    public init(id: UUID, owner: UInt32, interface: String, connectedAt: Date = Date(), peers: [PeerStatistics] = [], sampledAt: Date? = nil) {
        self.id = id
        self.owner = owner
        self.interface = interface
        self.connectedAt = connectedAt
        self.peers = peers
        self.sampledAt = sampledAt
    }
}

public struct HelperResponse: Codable, Sendable {
    public var success: Bool
    public var message: String
    public var runtime: TunnelRuntime?
    public var runtimes: [TunnelRuntime]?
    public init(success: Bool, message: String, runtime: TunnelRuntime? = nil, runtimes: [TunnelRuntime]? = nil) {
        self.success = success
        self.message = message
        self.runtime = runtime
        self.runtimes = runtimes
    }
}

public enum ShellQuoting {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
}
