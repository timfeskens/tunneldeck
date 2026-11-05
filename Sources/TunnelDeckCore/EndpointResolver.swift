import Foundation
import Darwin

/// Choose a numeric transport endpoint before handing a configuration to wg.
/// On dual-stack networks wg's first DNS result can select an IPv6 path that
/// handshakes successfully but stalls application traffic. Prefer IPv4 when
/// available; retain IPv6-only support and explicit numeric endpoint choices.
public enum EndpointResolver {
    public static func resolve(_ endpoint: String) throws -> String {
        try resolve(endpoint, lookup: addresses)
    }

    static func resolve(_ endpoint: String, lookup: (String) throws -> [String]) throws -> String {
        guard let separator = endpoint.lastIndex(of: ":"),
              let port = Int(endpoint[endpoint.index(after: separator)...]), (1...65535).contains(port) else {
            throw DeckError.message("Invalid WireGuard endpoint.")
        }
        let host = String(endpoint[..<separator])
        let unwrapped = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if let literal = try? IPNetwork(unwrapped, requirePrefix: false) {
            return format(literal, port: port)
        }
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            throw DeckError.message("Invalid WireGuard endpoint hostname.")
        }
        let candidates = try lookup(host).compactMap { try? IPNetwork($0, requirePrefix: false) }
        guard let selected = candidates.first(where: { $0.bytes.count == 4 }) ?? candidates.first else {
            throw DeckError.message("Cannot resolve a WireGuard endpoint. Check your network and DNS, then try again.")
        }
        return format(selected, port: port)
    }

    private static func format(_ address: IPNetwork, port: Int) -> String {
        address.bytes.count == 4 ? "\(address.address):\(port)" : "[\(address.address)]:\(port)"
    }

    private static func addresses(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw DeckError.message("Cannot resolve a WireGuard endpoint. Check your network and DNS, then try again.")
        }
        defer { freeaddrinfo(first) }
        var values: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let item = current {
            defer { current = item.pointee.ai_next }
            guard [AF_INET, AF_INET6].contains(item.pointee.ai_family), let address = item.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, item.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                values.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        return values
    }
}
