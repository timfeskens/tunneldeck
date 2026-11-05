import Foundation

public struct RouteTableEntry: Sendable {
    public let network: IPNetwork
    public let interface: String
    public let scoped: Bool
    public init(network: IPNetwork, interface: String, scoped: Bool = false) {
        self.network = network; self.interface = interface; self.scoped = scoped
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
            return RouteTableEntry(network: network, interface: fields[interfaceColumn], scoped: flags.contains("I"))
        }
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
    public var healthy: Bool { issues.isEmpty && duplicateInterfaces.isEmpty }
    public var title: String {
        if !duplicateInterfaces.isEmpty || issues.contains(where: \.conflict) { return "Routing conflict" }
        return issues.isEmpty ? "Active" : "Interface up, routes missing"
    }

    public init(routes: [IPNetwork], interface: String, table: [RouteTableEntry], duplicateInterfaces: [String] = [], checkedAt: Date = Date()) {
        self.checkedAt = checkedAt
        self.duplicateInterfaces = duplicateInterfaces.sorted()
        self.issues = routes.compactMap { route in
            let covering = table.filter { !$0.scoped && $0.network.prefix <= route.prefix && $0.network.overlaps(route) }
            let best = covering.max { $0.network.prefix < $1.network.prefix }
            let competing = table.first {
                !$0.scoped && $0.interface != interface && $0.interface != "lo0" &&
                $0.network.prefix >= route.prefix && $0.network.overlaps(route)
            }
            if let competing { return RouteIssue(network: route.description, actualInterface: competing.interface, conflict: true) }
            guard best?.interface == interface else {
                return RouteIssue(network: route.description, actualInterface: best?.interface,
                                  conflict: best?.interface.hasPrefix("utun") == true)
            }
            return nil
        }
    }
}
