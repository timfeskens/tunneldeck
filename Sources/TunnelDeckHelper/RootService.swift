import Foundation
import Darwin
import TunnelDeckCore

enum OperationLock {
    static func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open("/var/run/tunneldeck.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DeckError.message("Cannot open the network operation lock.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0 else { throw DeckError.message("Unsafe network operation lock.") }
        guard flock(descriptor, LOCK_EX) == 0 else { throw DeckError.message("Cannot acquire the network operation lock.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

final class RootService: NSObject, NSXPCListenerDelegate {
    static let queue = DispatchQueue(label: "codes.savvy.tunneldeck.network-operations")

    static func install(helper: Helper) throws -> HelperResponse {
        try helper.ensureDirectory(ServiceIdentity.base, mode: 0o755)
        try helper.ensureDirectory(ServiceIdentity.clients, mode: 0o755)
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let appExecutable = source.deletingLastPathComponent().appendingPathComponent("TunnelDeck")
        let requirement = try ServiceIdentity.requirement(for: appExecutable)
        _ = try ServiceIdentity.requirement(for: source)
        let runtime = try RuntimeInstaller.install(helper: helper)
        let enrollment = ServiceEnrollment(owner: helper.owner, requirement: requirement)
        try OnDemandService.replace(JSONEncoder().encode(enrollment), path: "\(ServiceIdentity.clients)/\(helper.owner).json", mode: 0o600, helper: helper)
        let binaryData = try Data(contentsOf: source)
        let changed = (try? Data(contentsOf: URL(fileURLWithPath: ServiceIdentity.binary))) != binaryData

        // Migrate the old on-demand-only service without disconnecting interfaces.
        let oldLabel = "codes.savvy.tunneldeck.on-demand"
        if try helper.run("/bin/launchctl", ["print", "system/" + oldLabel]).0 == 0 {
            guard try helper.run("/bin/launchctl", ["bootout", "system/" + oldLabel]).0 == 0 else {
                throw DeckError.message("Cannot unload the old on-demand helper. Running tunnels were left connected.")
            }
        }
        let oldPlist = "/Library/LaunchDaemons/\(oldLabel).plist"
        if FileManager.default.fileExists(atPath: oldPlist) { try FileManager.default.removeItem(atPath: oldPlist) }
        if changed { try OnDemandService.replace(binaryData, path: ServiceIdentity.binary, mode: 0o755, helper: helper) }
        let plist: [String: Any] = [
            "Label": ServiceIdentity.name, "ProgramArguments": [ServiceIdentity.binary, "--service"],
            "MachServices": [ServiceIdentity.name: true], "RunAtLoad": true, "KeepAlive": true,
            "AbandonProcessGroup": true, "ThrottleInterval": 10,
            "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        ]
        var contents = plist
        if let runtime {
            contents["EnvironmentVariables"] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TUNNELDECK_RUNTIME": runtime]
        }
        let path = "/Library/LaunchDaemons/\(ServiceIdentity.name).plist"
        let plistData = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        let settingsChanged = (try? Data(contentsOf: URL(fileURLWithPath: path))) != plistData
        try OnDemandService.replace(plistData, path: path, mode: 0o644, helper: helper)
        let running = try helper.run("/bin/launchctl", ["print", "system/" + ServiceIdentity.name]).0 == 0
        // kickstart does not reload EnvironmentVariables from a replaced plist.
        // AbandonProcessGroup keeps existing tunnel/route-monitor children alive.
        if running && settingsChanged {
            guard try helper.run("/bin/launchctl", ["bootout", "system/" + ServiceIdentity.name]).0 == 0 else {
                throw DeckError.message("Cannot reload the root service settings. Running tunnels were left connected.")
            }
        }
        let result = running && !settingsChanged
            ? try helper.run("/bin/launchctl", ["kickstart", "-k", "system/" + ServiceIdentity.name])
            : try helper.run("/bin/launchctl", ["bootstrap", "system", path])
        guard result.0 == 0 else { throw DeckError.message("macOS could not start the root service. Check Login Items & Extensions in System Settings.") }
        return HelperResponse(success: true, message: "Root service installed. Routine tunnel controls no longer require administrator prompts.")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let owner = connection.effectiveUserIdentifier
        guard owner > 0 else { return false }
        let path = "\(ServiceIdentity.clients)/\(owner).json"
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size <= 16384, let data = try? handle.read(upToCount: 16385),
              let enrollment = try? JSONDecoder().decode(ServiceEnrollment.self, from: data),
              enrollment.owner == owner, enrollment.version == ServiceIdentity.version else { return false }
        // Enforced by XPC for each message, not a racy PID-based signature check.
        connection.setCodeSigningRequirement(enrollment.requirement)
        connection.exportedInterface = NSXPCInterface(with: TunnelServiceProtocol.self)
        connection.exportedObject = ServiceSession(owner: owner)
        connection.resume()
        return true
    }

    static func run() {
        let service = RootService()
        let listener = NSXPCListener(machServiceName: ServiceIdentity.name)
        listener.delegate = service
        listener.resume()
        DispatchQueue.global(qos: .utility).async { OnDemandService.run() }
        withExtendedLifetime((listener, service)) { RunLoop.current.run() }
    }
}

final class ServiceSession: NSObject, TunnelServiceProtocol {
    let owner: UInt32
    init(owner: UInt32) { self.owner = owner }

    func perform(_ action: String, request data: Data, reply: @escaping (Data) -> Void) {
        RootService.queue.async {
            let response: HelperResponse
            do {
                guard data.count <= 262_144, ["ping", "status", "up", "down", "stats", "on-demand", "repair-routes"].contains(action) else {
                    throw DeckError.message("Invalid service request.")
                }
                let request = try JSONDecoder().decode(HelperRequest.self, from: data)
                if action == "ping" {
                    response = HelperResponse(success: true, message: "Ready")
                } else {
                    response = try OperationLock.withLock {
                        if action == "status" {
                            let ids = request.ids ?? [request.id]
                            guard ids.count <= 256 else { throw DeckError.message("Too many profiles in one status request.") }
                            var states: [TunnelRuntime] = []
                            let snapshot = try RoutingSnapshot(helper: Helper(owner: self.owner, request: request))
                            for id in ids {
                                let helper = Helper(owner: self.owner, request: HelperRequest(id: id))
                                guard let state = try? helper.readState(), helper.realInterface() == state.interface else { continue }
                                let sampled = try? helper.execute(action: "stats").runtime
                                states.append(try helper.inspect(sampled ?? state, snapshot: snapshot))
                            }
                            return HelperResponse(success: true, message: "Refreshed", runtimes: states)
                        }
                        let helper = Helper(owner: self.owner, request: request)
                        if action == "down", let settings = request.onDemand, !settings.enabled {
                            _ = try OnDemandService.configure(helper: helper, settings: settings)
                        }
                        var result = try helper.execute(action: action)
                        if let state = result.runtime { result.runtime = try helper.inspect(state) }
                        return result
                    }
                }
            } catch {
                response = HelperResponse(success: false, message: (error as? DeckError)?.localizedDescription ?? "The service could not complete the operation. Refresh before trying again.")
            }
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
