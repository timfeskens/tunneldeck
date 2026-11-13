import Foundation

public struct RouteTableEntry: Sendable {
    public let network: IPNetwork
    public let interface: String
    public let scoped: Bool
    public let directlyConnectedLAN: Bool
    public init(network: IPNetwork, interface: String, scoped: Bool = false, directlyConnectedLAN: Bool = false) {
        self.network = network; self.interface = interface; self.scoped = scoped
        self.directlyConnectedLAN = directlyConnectedLAN
    }

    /// Darwin netstat prints abbreviated IPv4 networks, such as 10.200/24.
    public static func parse(_ text: String) -> [RouteTableEntry] {
        var interfaceColumn: Int?
        var flagsColumn: Int?
        var ipv6 = false
        return text.components(separatedBy: .newlines).compactMap { line in
            if line == "Internet6:" { ipv6 = true }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.first == "Destination" {
                interfaceColumn = fields.firstIndex(of: "Netif")
                flagsColumn = fields.firstIndex(of: "Flags")
                return nil
            }
            guard let interfaceColumn, let flagsColumn, fields.count > max(interfaceColumn, flagsColumn),
                  let destination = fields.first, destination != "Destination" else { return nil }
            let flags = fields[flagsColumn]
            guard flags.contains("U") else { return nil }
            var value = destination
            if value == "default" { value = ipv6 ? "::/0" : "0.0.0.0/0" }
            if !value.contains(":") {
                let parts = value.split(separator: "/")
                var octets = String(parts[0]).split(separator: ".").map(String.init)
                guard (1...4).contains(octets.count) else { return nil }
                let prefix = parts.count == 2 ? String(parts[1]) : flags.contains("H") ? "32" : String(octets.count * 8)
                while octets.count < 4 { octets.append("0") }
                value = octets.joined(separator: ".") + "/" + prefix
            }
            guard let network = try? IPNetwork(value, requirePrefix: false) else { return nil }
            let interface = fields[interfaceColumn]
            let physical = interface.hasPrefix("en") && !interface.dropFirst(2).isEmpty && interface.dropFirst(2).allSatisfy(\.isNumber)
            return RouteTableEntry(network: network, interface: interface, scoped: flags.contains("I"),
                                   directlyConnectedLAN: physical && network.prefix > 0 && fields.count > 1 && fields[1].hasPrefix("link#") && !flags.contains("G") && !flags.contains("H"))
        }
    }
}

extension Array where Element == RouteTableEntry {
    /// Only a directly attached Ethernet/Wi-Fi subnet that fully contains the
    /// requested route qualifies. A gateway route or partial overlap does not.
    public func localRoute(covering route: IPNetwork) -> RouteTableEntry? {
        filter { !$0.scoped && $0.directlyConnectedLAN && $0.network.prefix <= route.prefix && $0.network.overlaps(route) }
            .max { $0.network.prefix < $1.network.prefix }
    }
}

public struct RouteIssue: Codable, Equatable, Sendable {
    public let network: String
    public let actualInterface: String?
    public let conflict: Bool
}

public struct RouteHealth: Codable, Equatable, Sendable {
    public let checkedAt: Date
    public let issues: [RouteIssue]
    public let duplicateInterfaces: [String]
    public let localRoutes: [RouteIssue]?
    public var healthy: Bool { issues.isEmpty && duplicateInterfaces.isEmpty }
    public var title: String {
        if !duplicateInterfaces.isEmpty || issues.contains(where: \.conflict) { return "Routing conflict" }
        return issues.isEmpty ? ((localRoutes ?? []).isEmpty ? "Active" : "Active — local LAN bypass") : "Interface up, routes missing"
    }

    public init(routes: [IPNetwork], interface: String, table: [RouteTableEntry], duplicateInterfaces: [String] = [], checkedAt: Date = Date()) {
        self.checkedAt = checkedAt
        self.duplicateInterfaces = duplicateInterfaces.sorted()
        var localRoutes: [RouteIssue] = []
        self.issues = routes.compactMap { route in
            let local = table.localRoute(covering: route)
            let covering = table.filter { !$0.scoped && $0.network.prefix <= route.prefix && $0.network.overlaps(route) }
            let best = covering.max { $0.network.prefix < $1.network.prefix }
            let competing = table.first {
                !$0.scoped && $0.interface != interface && $0.interface != "lo0" &&
                $0.interface != local?.interface &&
                $0.network.prefix >= route.prefix && $0.network.overlaps(route)
            }
            if let competing { return RouteIssue(network: route.description, actualInterface: competing.interface, conflict: true) }
            if let local {
                // A broader competing VPN route must not override a more
                // specific connected LAN, but an equally specific one is unsafe.
                if let vpn = covering.first(where: { $0.interface != interface && $0.interface.hasPrefix("utun") && $0.network.prefix >= local.network.prefix }) {
                    return RouteIssue(network: route.description, actualInterface: vpn.interface, conflict: true)
                }
                localRoutes.append(RouteIssue(network: route.description, actualInterface: local.interface, conflict: false))
                return nil
            }
            guard best?.interface == interface else {
                return RouteIssue(network: route.description, actualInterface: best?.interface,
                                  conflict: best?.interface.hasPrefix("utun") == true)
            }
            return nil
        }
        self.localRoutes = localRoutes
    }
}
