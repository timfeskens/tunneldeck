import Foundation
import Darwin

public enum DeckError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct IPNetwork: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]
    public let prefix: Int
    public let address: String
    public var description: String { "\(address)/\(prefix)" }

    public init(_ text: String, requirePrefix: Bool = true) throws {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 || (!requirePrefix && parts.count == 1) else {
            throw DeckError.message("An IP address must include a CIDR prefix, such as 192.168.68.74/32.")
        }
        let input = String(parts[0])
        let family = input.contains(":") ? AF_INET6 : AF_INET
        let length = family == AF_INET6 ? 16 : 4
        var buffer = [UInt8](repeating: 0, count: length)
        guard inet_pton(family, input, &buffer) == 1 else { throw DeckError.message("Invalid IP address or network.") }
        let mask = parts.count == 2 ? Int(parts[1]) : length * 8
        guard let mask, (0...(length * 8)).contains(mask) else { throw DeckError.message("Invalid CIDR prefix.") }
        var normalized = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = inet_ntop(family, &buffer, &normalized, socklen_t(normalized.count))
        self.bytes = buffer
        self.prefix = mask
        self.address = String(cString: normalized)
    }

    public func overlaps(_ other: IPNetwork) -> Bool {
        guard bytes.count == other.bytes.count else { return false }
        let bits = min(prefix, other.prefix)
        for index in 0..<(bits / 8) where bytes[index] != other.bytes[index] { return false }
        let remaining = bits % 8
        if remaining == 0 { return true }
        let mask = UInt8(0xff << (8 - remaining) & 0xff)
        return bytes[bits / 8] & mask == other.bytes[bits / 8] & mask
    }
}

public struct WireGuardPeer: Sendable {
    public let publicKey: String
    public let presharedKey: String?
    public let endpoint: String?
    public let allowedIPs: [IPNetwork]
    public let keepalive: Int?
}

public struct WireGuardConfiguration: Sendable {
    public let privateKey: String
    public let addresses: [IPNetwork]
    public let dns: [String]
    public let mtu: Int?
    public let listenPort: Int?
    public let peers: [WireGuardPeer]
    public var routes: [IPNetwork] { peers.flatMap(\.allowedIPs) }

    public init(text: String) throws {
        guard text.utf8.count <= 131_072, !text.contains("\0") else {
            throw DeckError.message("Configuration is too large or contains invalid characters.")
        }
        var section = ""
        var interface: [String: String] = [:]
        var peerFields: [[String: String]] = []
        let interfaceKeys: Set<String> = ["privatekey", "address", "dns", "mtu", "listenport"]
        let peerKeys: Set<String> = ["publickey", "presharedkey", "endpoint", "allowedips", "persistentkeepalive"]
        let forbidden: Set<String> = ["preup", "postup", "predown", "postdown", "saveconfig", "table"]
        for (number, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "[Interface]" {
                guard section.isEmpty else { throw DeckError.message("Use exactly one [Interface] section, before all peers.") }
                section = "interface"
                continue
            }
            if line == "[Peer]" {
                guard !section.isEmpty else { throw DeckError.message("The [Interface] section must come first.") }
                section = "peer"
                peerFields.append([:])
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { throw DeckError.message("Expected a setting on line \(number + 1).") }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !forbidden.contains(key) else {
                throw DeckError.message("Hooks, SaveConfig, and Table are not allowed. Remove that setting before importing.")
            }
            guard !value.isEmpty else { throw DeckError.message("Empty setting on line \(number + 1).") }
            if section == "interface", interfaceKeys.contains(key) {
                if let existing = interface[key], ["address", "dns"].contains(key) { interface[key] = existing + ", " + value }
                else {
                    guard interface[key] == nil else { throw DeckError.message("Duplicate interface setting on line \(number + 1).") }
                    interface[key] = value
                }
            } else if section == "peer", peerKeys.contains(key) {
                let index = peerFields.count - 1
                if let existing = peerFields[index][key], key == "allowedips" { peerFields[index][key] = existing + ", " + value }
                else {
                    guard peerFields[index][key] == nil else { throw DeckError.message("Duplicate peer setting on line \(number + 1).") }
                    peerFields[index][key] = value
                }
            } else { throw DeckError.message("Unsupported section or setting on line \(number + 1).") }
        }
        func key(_ value: String?) throws -> String {
            guard let value, let data = Data(base64Encoded: value), data.count == 32 else {
                throw DeckError.message("WireGuard keys must be base64-encoded 32-byte values.")
            }
            return data.base64EncodedString()
        }
        func list(_ value: String?) -> [String] {
            (value ?? "").split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func integer(_ value: String?, range: ClosedRange<Int>) throws -> Int? {
            guard let value else { return nil }
            guard let number = Int(value), range.contains(number) else { throw DeckError.message("A numeric setting is outside its valid range.") }
            return number
        }
        privateKey = try key(interface["privatekey"])
        guard interface["address"] != nil else { throw DeckError.message("An interface Address is required.") }
        addresses = try list(interface["address"]).map { try IPNetwork($0, requirePrefix: false) }
        mtu = try integer(interface["mtu"], range: 576...9000)
        listenPort = try integer(interface["listenport"], range: 0...65535)
        dns = interface["dns"] == nil ? [] : list(interface["dns"])
        guard dns.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 253 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".:-_".contains($0)) } }) else {
            throw DeckError.message("Invalid DNS setting.")
        }
        guard !peerFields.isEmpty else { throw DeckError.message("At least one peer is required.") }
        var parsedPeers: [WireGuardPeer] = []
        var publicKeys = Set<String>()
        for fields in peerFields {
            let publicKey = try key(fields["publickey"])
            guard publicKeys.insert(publicKey).inserted else { throw DeckError.message("Duplicate peer public key.") }
            let psk = try fields["presharedkey"].map { try key($0) }
            guard fields["allowedips"] != nil else { throw DeckError.message("Each peer needs AllowedIPs.") }
            let routes = try list(fields["allowedips"]).map { try IPNetwork($0) }
            // Deliberately exclude default routes in v1: wg-quick's global endpoint and DNS
            // machinery cannot safely coordinate multiple independent default-route owners.
            guard routes.allSatisfy({ $0.prefix > 0 }) else { throw DeckError.message("This version supports split tunnels only. Default routes (/0) are not allowed.") }
            if let endpoint = fields["endpoint"] { try Self.validateEndpoint(endpoint) }
            parsedPeers.append(WireGuardPeer(publicKey: publicKey, presharedKey: psk, endpoint: fields["endpoint"], allowedIPs: routes,
                                            keepalive: try integer(fields["persistentkeepalive"], range: 0...65535)))
        }
        for (index, peer) in parsedPeers.enumerated() {
            if parsedPeers.dropFirst(index + 1).contains(where: { other in peer.allowedIPs.contains(where: { route in other.allowedIPs.contains(where: route.overlaps) }) }) {
                throw DeckError.message("AllowedIPs overlap between peers. Use disjoint routes for predictable routing.")
            }
        }
        peers = parsedPeers
    }

    private static func validateEndpoint(_ value: String) throws {
        guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) else {
            throw DeckError.message("An endpoint must be a host and port, such as vpn.example.com:51820.")
        }
        let host = String(value[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") {
            let ip = try IPNetwork(String(host.dropFirst().dropLast()), requirePrefix: false)
            guard ip.bytes.count == 16 else { throw DeckError.message("Invalid IPv6 endpoint.") }
        } else {
            guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
                  host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
                throw DeckError.message("Invalid endpoint hostname.")
            }
        }
    }

    /// Always generated from validated values; never execute raw imported configuration.
    /// DNS is intentionally omitted so independently managed tunnels cannot overwrite it.
    public var runtimeText: String {
        runtimeText(endpoints: peers.map(\.endpoint))
    }

    /// Resolution affects only root-owned runtime input, never the imported
    /// configuration in Keychain. Resolve again after reconnect/network changes.
    public func runtimeText(resolvingEndpoints resolve: (String) throws -> String) throws -> String {
        runtimeText(endpoints: try peers.map { try $0.endpoint.map(resolve) })
    }

    private func runtimeText(endpoints: [String?]) -> String {
        var lines = ["[Interface]", "PrivateKey = \(privateKey)", "Address = \(addresses.map(\.description).joined(separator: ", "))"]
        if let mtu { lines.append("MTU = \(mtu)") }
        if let listenPort { lines.append("ListenPort = \(listenPort)") }
        for (index, peer) in peers.enumerated() {
            lines += ["", "[Peer]", "PublicKey = \(peer.publicKey)"]
            if let psk = peer.presharedKey { lines.append("PresharedKey = \(psk)") }
            if let endpoint = endpoints[index] { lines.append("Endpoint = \(endpoint)") }
            lines.append("AllowedIPs = \(peer.allowedIPs.map(\.description).joined(separator: ", "))")
            if let keepalive = peer.keepalive { lines.append("PersistentKeepalive = \(keepalive)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func conflicts(with other: WireGuardConfiguration) -> Bool {
        let ours = routes + addresses
        let theirs = other.routes + other.addresses
        return ours.contains { route in theirs.contains(where: route.overlaps) }
    }
}
