import Foundation
import TunnelDeckCore

struct RoutingSnapshot {
    let table: [RouteTableEntry]
    let addresses: [String: Set<String>]

    init(helper: Helper) throws {
        var entries: [RouteTableEntry] = []
        for family in ["inet", "inet6"] {
            let result = try helper.run("/usr/sbin/netstat", ["-rn", "-f", family])
            guard result.0 == 0 else { throw DeckError.message("Cannot inspect the system routing table.") }
            entries += RouteTableEntry.parse(result.1)
        }
        table = entries
        let interfaces = try helper.run("/sbin/ifconfig", ["-a"])
        guard interfaces.0 == 0 else { throw DeckError.message("Cannot inspect interface addresses.") }
        var found: [String: Set<String>] = [:]
        var name: String?
        for line in interfaces.1.components(separatedBy: .newlines) {
            if !line.hasPrefix("\t"), !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") {
                name = String(line[..<colon]); continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let name, fields.count >= 2, ["inet", "inet6"].contains(fields[0]),
                  let address = try? IPNetwork(String(fields[1]).components(separatedBy: "%")[0], requirePrefix: false) else { continue }
            found[name, default: []].insert(address.address)
        }
        addresses = found
    }

    func duplicates(configuration: WireGuardConfiguration, excluding interface: String?) -> [String] {
        let ours = Set(configuration.addresses.map(\.address))
        return addresses.filter { $0.key != interface && !$0.value.isDisjoint(with: ours) }.map(\.key).sorted()
    }

    func health(configuration: WireGuardConfiguration, interface: String) -> RouteHealth {
        RouteHealth(routes: configuration.routes, interface: interface, table: table,
                    duplicateInterfaces: duplicates(configuration: configuration, excluding: interface))
    }
}

extension Helper {
    func runtimeConfiguration() throws -> WireGuardConfiguration {
        try WireGuardConfiguration(text: String(contentsOfFile: configPath, encoding: .utf8))
    }

    func inspect(_ state: TunnelRuntime, snapshot: RoutingSnapshot? = nil) throws -> TunnelRuntime {
        var state = state
        let snapshot = try snapshot ?? RoutingSnapshot(helper: self)
        state.routeHealth = snapshot.health(configuration: try runtimeConfiguration(), interface: state.interface)
        return state
    }

    func repairRoutes() throws -> HelperResponse {
        let state = try readState()
        guard realInterface() == state.interface else { throw DeckError.message("The tunnel is not running. Connect it first.") }
        let configuration = try runtimeConfiguration()
        var snapshot = try RoutingSnapshot(helper: self)
        let health = snapshot.health(configuration: configuration, interface: state.interface)
        guard health.duplicateInterfaces.isEmpty, !health.issues.contains(where: \.conflict) else {
            throw DeckError.message("Another interface uses this VPN address or owns overlapping routes. Deactivate that copy and its on-demand rule in the other VPN app, then try Repair Routes again. No routes were changed.")
        }
        // Never delete or replace another interface's route. Only add absent
        // entries using our validated saved AllowedIPs; the user explicitly asks.
        for issue in health.issues {
            let route = try IPNetwork(issue.network)
            snapshot = try RoutingSnapshot(helper: self)
            let current = snapshot.health(configuration: configuration, interface: state.interface)
            guard current.duplicateInterfaces.isEmpty, !current.issues.contains(where: \.conflict) else {
                throw DeckError.message("A competing VPN became active during repair. Repair stopped; refresh to inspect the current routes.")
            }
            guard current.issues.contains(where: { $0.network == issue.network }) else { continue }
            let result = try run("/sbin/route", ["-q", "-n", "add", route.bytes.count == 4 ? "-inet" : "-inet6", route.description, "-interface", state.interface])
            guard result.0 == 0 else { throw DeckError.message("A route could not be added. Repair stopped without deleting existing routes. Refresh to inspect partial progress.") }
        }
        let updated = try inspect(state)
        guard updated.routeHealth?.healthy == true else { throw DeckError.message("Route repair did not pass verification. No other interface's routes were replaced.") }
        return HelperResponse(success: true, message: "Routes repaired and verified. Check the handshake to confirm peer reachability.", runtime: updated)
    }
}
