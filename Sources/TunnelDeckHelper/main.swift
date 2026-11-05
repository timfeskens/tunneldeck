import Foundation
import Darwin
import TunnelDeckCore

// The approved installer deploys a root-owned XPC service. Routine operations
// are restricted to enrolled signing identities and their authenticated UID.
struct Helper {
    let owner: UInt32
    let request: HelperRequest
    let dependencies = Dependencies.detect()
    let manager = FileManager.default
    var directory: String { "/var/run/tunneldeck/\(owner)" }
    var name: String { TunnelProfile.interfaceName(for: request.id) }
    var configPath: String { "\(directory)/\(name).conf" }
    var statePath: String { "\(directory)/\(name).json" }

    func ensureDirectory(_ path: String, mode: mode_t) throws {
        if mkdir(path, mode) != 0 && errno != EEXIST { throw DeckError.message("Cannot create runtime directory.") }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == 0, info.st_mode & 0o022 == 0 else {
            throw DeckError.message("Unsafe runtime directory. Refusing privileged operation.")
        }
    }

    func write(_ data: Data, to path: String, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw DeckError.message("Cannot safely create runtime file.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    func readState() throws -> TunnelRuntime {
        let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
        let runtime = try JSONDecoder().decode(TunnelRuntime.self, from: data)
        guard runtime.id == request.id, runtime.owner == owner else { throw DeckError.message("Tunnel identity mismatch.") }
        return runtime
    }

    func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        var arguments = arguments
        if executable == dependencies.bash, arguments.first == dependencies.quick {
            // Darwin wg-quick waits forever when it detects launchd ancestry.
            // Our own daemon supervises/retries the tunnel; do not let a child
            // route monitor keep the one-shot request or daemon loop blocked.
            let source = try String(contentsOfFile: dependencies.quick, encoding: .utf8)
            let waitLine = "[[ -n $LAUNCHED_BY_LAUNCHD ]] && wait"
            guard source.components(separatedBy: waitLine).count == 2 else {
                throw DeckError.message("This wg-quick version is not compatible with TunnelDeck supervision.")
            }
            let script = directory + "/supervised-wg-quick"
            if manager.fileExists(atPath: script) { try manager.removeItem(atPath: script) }
            try write(Data(source.replacingOccurrences(of: waitLine, with: ": # supervised by TunnelDeck").utf8), to: script, mode: 0o600)
            arguments[0] = script
        }
        task.arguments = arguments
        task.environment = ["PATH": "\(dependencies.prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": "/var/root",
                            "WG_QUICK_USERSPACE_IMPLEMENTATION": dependencies.go]
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func realInterface() -> String? {
        let path = "/var/run/wireguard/\(name).name"
        guard let value = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("utun"), !value.dropFirst(4).isEmpty, value.dropFirst(4).allSatisfy(\.isNumber),
              manager.fileExists(atPath: "/var/run/wireguard/\(value).sock") else { return nil }
        return value
    }

    func execute(action: String) throws -> HelperResponse {
        try ensureDirectory("/var/run/tunneldeck", mode: 0o755)
        try ensureDirectory(directory, mode: 0o755)
        if action == "on-demand" {
            guard let settings = request.onDemand else { throw DeckError.message("Missing on-demand settings.") }
            try settings.validate()
            if settings.enabled, !dependencies.missing.isEmpty { throw DeckError.message("Install dependencies: brew install wireguard-tools wireguard-go bash") }
            return try OnDemandService.configure(helper: self, settings: settings)
        }
        guard dependencies.missing.isEmpty else { throw DeckError.message("Install dependencies: brew install wireguard-tools wireguard-go bash") }
        switch action {
        case "repair-routes":
            return try repairRoutes()
        case "up":
            guard let text = request.configuration else { throw DeckError.message("Missing configuration.") }
            let configuration = try WireGuardConfiguration(text: text)
            if let actual = realInterface() {
                let state = try readState()
                guard actual == state.interface else { throw DeckError.message("Tunnel identity mismatch. No interfaces were changed.") }
                return HelperResponse(success: true, message: "Interface already running. Check route health.", runtime: try inspect(state))
            }
            let routing = try RoutingSnapshot(helper: self)
            let duplicates = routing.duplicates(configuration: configuration, excluding: nil)
            let routeConflicts = RouteHealth(routes: configuration.routes, interface: "", table: routing.table).issues.filter(\.conflict)
            guard duplicates.isEmpty, routeConflicts.isEmpty else {
                throw DeckError.message("Another interface uses this VPN address or owns overlapping routes. Deactivate that copy and disable its on-demand rule in the other VPN app before connecting. No interfaces were changed.")
            }
            // Enforce conflicts again in the privileged layer, across all TunnelDeck users.
            let enumerator = manager.enumerator(atPath: "/var/run/tunneldeck")
            while let relative = enumerator?.nextObject() as? String {
                guard relative.hasSuffix(".json") else { continue }
                let url = URL(fileURLWithPath: "/var/run/tunneldeck/" + relative)
                guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(TunnelRuntime.self, from: data),
                      state.id != request.id, manager.fileExists(atPath: "/var/run/wireguard/\(state.interface).sock") else { continue }
                let otherPath = url.deletingPathExtension().appendingPathExtension("conf")
                let other = try WireGuardConfiguration(text: String(contentsOf: otherPath, encoding: .utf8))
                guard !configuration.conflicts(with: other) else { throw DeckError.message("Routes or interface networks overlap with another TunnelDeck tunnel. Disconnect it first.") }
            }
            // Resolve before changing runtime files or creating an interface.
            let runtimeText = try configuration.runtimeText(resolvingEndpoints: EndpointResolver.resolve)
            if manager.fileExists(atPath: statePath) { _ = try readState() }
            // Stale files can only exist in the verified root-owned directory.
            if manager.fileExists(atPath: configPath) { try manager.removeItem(atPath: configPath) }
            if manager.fileExists(atPath: statePath) { try manager.removeItem(atPath: statePath) }
            try write(Data(runtimeText.utf8), to: configPath, mode: 0o600)
            let result = try run(dependencies.bash, [dependencies.quick, "up", configPath])
            guard result.0 == 0, let actual = realInterface() else {
                // wg-quick may have created an interface before failing; request its normal cleanup.
                if realInterface() != nil { _ = try? run(dependencies.bash, [dependencies.quick, "down", configPath]) }
                if realInterface() == nil { try? manager.removeItem(atPath: configPath) }
                // Never echo dependency output: it could contain a key on malformed input.
                throw DeckError.message("WireGuard could not start (exit \(result.0)). Check endpoint reachability, keys, and existing routes. No raw command output was logged.")
            }
            let runtime = TunnelRuntime(id: request.id, owner: owner, interface: actual)
            do { try write(JSONEncoder().encode(runtime), to: statePath, mode: 0o644) }
            catch {
                _ = try? run(dependencies.bash, [dependencies.quick, "down", configPath])
                throw error
            }
            return HelperResponse(success: true, message: "Interface connected. DNS settings were preserved.", runtime: try inspect(runtime))
        case "down":
            let state = try readState()
            if let actual = realInterface() {
                guard actual == state.interface else { throw DeckError.message("Interface changed; refusing to disconnect an unrelated tunnel.") }
                let result = try run(dependencies.bash, [dependencies.quick, "down", configPath])
                guard result.0 == 0, realInterface() == nil else { throw DeckError.message("Disconnect failed. The saved runtime configuration was retained for recovery.") }
            }
            try? manager.removeItem(atPath: configPath)
            try manager.removeItem(atPath: statePath)
            return HelperResponse(success: true, message: "Disconnected.")
        case "stats":
            var state = try readState()
            guard realInterface() == state.interface else { throw DeckError.message("Tunnel is no longer running.") }
            var peers: [String: PeerStatistics] = [:]
            for field in ["endpoints", "latest-handshakes", "transfer"] {
                let result = try run(dependencies.wg, ["show", state.interface, field])
                guard result.0 == 0 else { throw DeckError.message("Could not read peer statistics.") }
                for line in result.1.split(separator: "\n") {
                    let values = line.split(whereSeparator: \.isWhitespace).map(String.init)
                    guard values.count >= 2 else { continue }
                    var peer = peers[values[0]] ?? PeerStatistics(endpoint: "", latestHandshake: 0, received: 0, sent: 0)
                    switch field {
                    case "endpoints": peer.endpoint = values[1]
                    case "latest-handshakes": peer.latestHandshake = Int64(values[1]) ?? 0
                    default:
                        guard values.count == 3 else { continue }
                        peer.received = UInt64(values[1]) ?? 0
                        peer.sent = UInt64(values[2]) ?? 0
                    }
                    peers[values[0]] = peer
                }
            }
            state.peers = peers.keys.sorted().compactMap { peers[$0] }
            state.sampledAt = Date()
            return HelperResponse(success: true, message: "Statistics refreshed.", runtime: state)
        default: throw DeckError.message("Unsupported operation.")
        }
    }
}

func main() -> HelperResponse {
    do {
        let args = CommandLine.arguments
        guard geteuid() == 0, args.count == 4, ["install-service"].contains(args[1]),
              let owner = UInt32(args[2]), owner > 0 else { throw DeckError.message("Administrator authorization is required.") }
        let fd = open(args[3], O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DeckError.message("Cannot open request file.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
              info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size > 0, info.st_size <= 262_144 else {
            throw DeckError.message("Unsafe request file permissions or size.")
        }
        let data = try file.read(upToCount: 262_145) ?? Data()
        guard data.count <= 262_144 else { throw DeckError.message("Request too large.") }
        let request = try JSONDecoder().decode(HelperRequest.self, from: data)
        // Serialize changes from multiple app instances before checking routes/state.
        let lock = open("/var/run/tunneldeck.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw DeckError.message("Cannot acquire operation lock.") }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_uid == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_mode & 0o077 == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw DeckError.message("Another tunnel operation is in progress, or the lock is unsafe.")
        }
        defer { flock(lock, LOCK_UN) }
        return try RootService.install(helper: Helper(owner: owner, request: request))
    } catch {
        // Foundation errors may contain paths but no config/key contents. Decoder
        // internals are deliberately not exposed.
        let message = (error as? DeckError)?.localizedDescription ?? "The operation failed. Runtime files were retained when needed for recovery."
        return HelperResponse(success: false, message: message)
    }
}

if CommandLine.arguments == [CommandLine.arguments[0], "--service"], geteuid() == 0 {
    RootService.run()
} else {
    let response = main()
    if let data = try? JSONEncoder().encode(response) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
