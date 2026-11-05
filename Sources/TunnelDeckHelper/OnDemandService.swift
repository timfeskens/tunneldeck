import Foundation
import SystemConfiguration
import CoreWLAN
import Darwin
import TunnelDeckCore

enum OnDemandService {
    static let base = "/Library/Application Support/TunnelDeck"

    static func configure(helper: Helper, settings: OnDemandSettings) throws -> HelperResponse {
        try helper.ensureDirectory(base, mode: 0o755)
        try helper.ensureDirectory(OnDemandStatus.root, mode: 0o755)
        let directory = OnDemandStatus.root + "/\(helper.owner)"
        try helper.ensureDirectory(directory, mode: 0o755)
        let recordPath = directory + "/\(helper.name).json"
        let statusPath = OnDemandStatus.statusPath(owner: helper.owner, id: helper.request.id)
        if settings.enabled {
            guard let text = helper.request.configuration else { throw DeckError.message("Missing on-demand configuration.") }
            let configuration = try WireGuardConfiguration(text: text)
            let record = OnDemandRecord(id: helper.request.id, owner: helper.owner, configuration: configuration.runtimeText, settings: settings)
            try replace(JSONEncoder().encode(record), path: recordPath, mode: 0o600, helper: helper)
            try writeStatus(OnDemandStatus(id: record.id, owner: record.owner, settings: settings), helper: helper)
        } else {
            if FileManager.default.fileExists(atPath: recordPath) {
                let existing = try loadRecord(recordPath)
                guard existing.id == helper.request.id, existing.owner == helper.owner else { throw DeckError.message("On-demand identity mismatch.") }
                try FileManager.default.removeItem(atPath: recordPath)
            }
            // Disabling auto-activation deliberately leaves the tunnel connected,
            // just as turning off an automation should not disrupt active work.
            try replace(JSONEncoder().encode(OnDemandStatus(id: helper.request.id, owner: helper.owner, settings: settings, message: "Off")), path: statusPath, mode: 0o644, helper: helper)
        }
        return HelperResponse(success: true, message: settings.enabled ? "On-demand enabled." : "On-demand disabled. Any active tunnel was left connected.")
    }

    static func replace(_ data: Data, path: String, mode: mode_t, helper: Helper) throws {
        let temporary = path + "." + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        try helper.write(data, to: temporary, mode: mode)
        guard rename(temporary, path) == 0 else { throw DeckError.message("Cannot save on-demand settings.") }
    }

    static func loadRecord(_ path: String) throws -> OnDemandRecord {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw DeckError.message("Cannot read on-demand configuration.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= 262_144 else { throw DeckError.message("Unsafe on-demand configuration.") }
        let record = try JSONDecoder().decode(OnDemandRecord.self, from: handle.read(upToCount: 262_145) ?? Data())
        guard record.owner > 0 else { throw DeckError.message("Invalid on-demand owner.") }
        try record.settings.validate()
        _ = try WireGuardConfiguration(text: record.configuration)
        return record
    }

    static func writeStatus(_ status: OnDemandStatus, helper: Helper) throws {
        let path = OnDemandStatus.statusPath(owner: status.owner, id: status.id)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let previous = try? JSONDecoder().decode(OnDemandStatus.self, from: data), previous == status { return }
        try replace(JSONEncoder().encode(status), path: path, mode: 0o644, helper: helper)
    }

    static func network() -> NetworkSnapshot {
        guard let store = SCDynamicStoreCreate(nil, "TunnelDeck" as CFString, nil, nil) else {
            return NetworkSnapshot(reachable: false, wiFi: false, ethernet: false)
        }
        let interfaces = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        let types: [String: String] = Dictionary(interfaces.compactMap { item in
            guard let name = SCNetworkInterfaceGetBSDName(item) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(item) as String? else { return nil }
            return (name, type)
        }, uniquingKeysWith: { first, _ in first })
        var wifi = false
        var ethernet = false
        var signatures: [String] = []
        for family in ["IPv4", "IPv6"] {
            guard let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
                  let primary = global["PrimaryInterface"] as? String, let type = types[primary] else { continue }
            if type == kSCNetworkInterfaceTypeIEEE80211 as String { wifi = true }
            else if type == kSCNetworkInterfaceTypeEthernet as String { ethernet = true }
            else { continue } // Never match a VPN/tunnel as Ethernet.
            let interface = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(primary)/\(family)" as CFString) as? [String: Any]
            signatures.append("\(primary):\(global["Router"] ?? ""):\(interface?["Addresses"] ?? "")")
        }
        let ssid = wifi ? CWWiFiClient.shared().interface()?.ssid() : nil
        return NetworkSnapshot(reachable: wifi || ethernet, wiFi: wifi, ethernet: ethernet,
                               ssid: ssid, signature: signatures.sorted().joined(separator: "|") + (ssid ?? ""))
    }

    static func run() {
        var previousNetwork: [UUID: NetworkSnapshot] = [:]
        var lastAttempt: [UUID: Date] = [:]
        while true {
            autoreleasepool {
                // Same lock used by manual operations. Never race configuration,
                // route changes, or on-demand cancellation with the app.
                let lock = open("/var/run/tunneldeck.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
                guard lock >= 0 else { return }
                defer { close(lock) }
                var info = stat()
                guard fstat(lock, &info) == 0, info.st_uid == 0, info.st_mode & 0o077 == 0,
                      info.st_mode & S_IFMT == S_IFREG, flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
                defer { flock(lock, LOCK_UN) }
                let snapshot = network()
                guard let enumerator = FileManager.default.enumerator(atPath: OnDemandStatus.root) else { return }
                var present = Set<UUID>()
                while let relative = enumerator.nextObject() as? String {
                    guard relative.hasSuffix(".json"), !relative.hasSuffix(".status.json"),
                          let record = try? loadRecord(OnDemandStatus.root + "/" + relative), record.settings.enabled,
                          relative == "\(record.owner)/\(TunnelProfile.interfaceName(for: record.id)).json" else { continue }
                    present.insert(record.id)
                    let helper = Helper(owner: record.owner, request: HelperRequest(id: record.id, configuration: record.configuration))
                    do {
                        let changed = previousNetwork[record.id].map { $0 != snapshot } ?? false
                        previousNetwork[record.id] = snapshot
                        let matches = record.settings.matches(snapshot)
                        // Reset the interface on a physical network change. This
                        // re-resolves endpoint hostnames after sleep/roaming.
                        if helper.realInterface() != nil && (!matches || changed) { _ = try helper.execute(action: "down") }
                        if matches, helper.realInterface() == nil {
                            if !changed, let last = lastAttempt[record.id], Date().timeIntervalSince(last) < 30 { continue }
                            lastAttempt[record.id] = Date()
                            _ = try helper.execute(action: "up")
                        }
                        let message: String
                        if helper.realInterface() != nil { message = "Active on demand." }
                        else if record.settings.wiFi && snapshot.wiFi && record.settings.wiFiRule != .any && snapshot.ssid == nil {
                            message = "Wi-Fi name is unavailable to macOS background services. Use Any network or allow SSID access."
                        } else { message = "Waiting for a matching network." }
                        try writeStatus(OnDemandStatus(id: record.id, owner: record.owner, settings: record.settings, message: message), helper: helper)
                    } catch {
                        let message = (error as? DeckError)?.localizedDescription ?? "On-demand operation failed; it will retry automatically."
                        try? writeStatus(OnDemandStatus(id: record.id, owner: record.owner, settings: record.settings, message: message), helper: helper)
                    }
                }
                previousNetwork = previousNetwork.filter { present.contains($0.key) }
                lastAttempt = lastAttempt.filter { present.contains($0.key) }
            }
            Thread.sleep(forTimeInterval: 5)
        }
    }
}
