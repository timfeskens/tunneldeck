import AppKit
import Foundation
import TunnelDeckCore

@MainActor
final class TunnelStore: ObservableObject {
    @Published private(set) var profiles: [TunnelProfile] = []
    @Published private(set) var runtime: [UUID: TunnelRuntime] = [:]
    @Published private(set) var onDemand: [UUID: OnDemandStatus] = [:]
    @Published var selection: UUID?
    @Published var busy: UUID?
    @Published var error: String?
    @Published private(set) var serviceReady = false
    @Published var installingService = false
    let dependencies = Dependencies.detect()
    private var timer: Timer?
    private var storageAvailable = true
    private var refreshingService = false
    private let metadataURL: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TunnelDeck", isDirectory: true)
        metadataURL = directory.appendingPathComponent("profiles.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                profiles = try JSONDecoder().decode([TunnelProfile].self, from: Data(contentsOf: metadataURL))
            }
        } catch {
            storageAvailable = false
            self.error = "Cannot load saved profiles. Existing data has not been overwritten. Restore or repair profiles.json before saving new profiles."
        }
        selection = profiles.first?.id
        refresh()
        refreshFromService()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.refreshFromService() }
        }
    }

    var selected: TunnelProfile? { profiles.first { $0.id == selection } }
    var connectedCount: Int { runtime.count }

    func statusTitle(_ id: UUID) -> String {
        guard let state = runtime[id] else { return "Inactive" }
        guard serviceReady, let health = state.routeHealth else { return "Interface up — checking routes" }
        return health.title
    }

    func statusColor(_ id: UUID) -> NSColor {
        guard runtime[id] != nil else { return .secondaryLabelColor }
        return serviceReady && runtime[id]?.routeHealth?.healthy == true ? .systemGreen : .systemOrange
    }

    private func persist(_ updated: [TunnelProfile]) throws {
        guard storageAvailable else { throw DeckError.message("Profile storage could not be loaded. Saving is disabled to protect existing data.") }
        let data = try JSONEncoder().encode(updated)
        try data.write(to: metadataURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        profiles = updated
    }

    func configuration(for profile: TunnelProfile) throws -> String { try SecureStore.read(profile.id) }

    func exportArchive(selecting ids: Set<UUID>) throws -> Data {
        guard busy == nil, !installingService else { throw DeckError.message("Wait for the current operation to finish.") }
        guard !ids.isEmpty, ids.count <= 256 else { throw DeckError.message("Select between 1 and 256 tunnels to export.") }
        let selected = profiles.filter { ids.contains($0.id) }
        guard selected.count == ids.count else { throw DeckError.message("The selected tunnel list changed. Select the tunnels again.") }
        let tunnels = try selected.map { ImportedTunnel(name: $0.name, text: try configuration(for: $0)) }
        return try ArchiveExport.make(tunnels: tunnels)
    }

    /// Validate the entire archive before saving anything. Never replace existing
    /// profiles; repeated names receive a suffix, including within one archive.
    func importTunnels(_ tunnels: [ImportedTunnel]) throws {
        guard storageAvailable else { throw DeckError.message("Profile storage could not be loaded. Importing is disabled to protect existing data.") }
        guard busy == nil else { throw DeckError.message("Wait for the current operation to finish.") }
        var updated = profiles
        var prepared: [(TunnelProfile, String)] = []
        for tunnel in tunnels {
            let configuration = try WireGuardConfiguration(text: tunnel.text)
            let base = tunnel.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty, base.count <= 80 else { throw DeckError.message("A tunnel has an invalid name.") }
            var name = base
            var suffix = 2
            while updated.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let ending = " (\(suffix))"
                name = String(base.prefix(80 - ending.count)) + ending
                suffix += 1
            }
            let profile = TunnelProfile(name: name, configuration: configuration)
            guard !updated.contains(where: { $0.interfaceName == profile.interfaceName }) else {
                throw DeckError.message("Tunnel identifier collision; please try importing again.")
            }
            prepared.append((profile, tunnel.text))
            updated.append(profile)
        }
        var saved: [UUID] = []
        do {
            for (profile, text) in prepared {
                try SecureStore.save(text, id: profile.id)
                saved.append(profile.id)
            }
            try persist(updated)
        } catch {
            let failures = saved.filter { id in
                do { try SecureStore.delete(id); return false } catch { return true }
            }
            if !failures.isEmpty {
                throw DeckError.message("Import failed. Some newly created Keychain items could not be removed; existing tunnels were not replaced.")
            }
            throw DeckError.message("Import failed; no tunnels were imported. Existing profiles were preserved.")
        }
        selection = prepared.first?.0.id ?? selection
    }

    func save(name: String, text: String, editing: TunnelProfile?) async throws {
        guard storageAvailable else { throw DeckError.message("Profile storage could not be loaded. Saving is disabled to protect existing data.") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw DeckError.message("Enter a tunnel name of 1–80 characters.") }
        guard busy == nil, !installingService else { throw DeckError.message("Wait for the current operation to finish.") }
        let configuration = try WireGuardConfiguration(text: text)
        let profile = TunnelProfile(id: editing?.id ?? UUID(), name: trimmed, configuration: configuration)
        guard !profiles.contains(where: { $0.id != profile.id && $0.interfaceName == profile.interfaceName }) else {
            throw DeckError.message("Tunnel identifier collision; please try adding it again.")
        }
        let previousText = editing != nil ? try SecureStore.read(profile.id) : nil
        let previousProfiles = profiles
        // Let the service decide whether the tunnel is active under its lock;
        // the UI's most recent status sample can be stale (on-demand/other app).
        let needsServiceUpdate = editing != nil
        busy = profile.id
        defer { busy = nil; refresh(); refreshFromService() }
        try SecureStore.save(text, id: profile.id)
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        do {
            try persist(updated)
            if needsServiceUpdate {
                let response = try await PrivilegedClient.perform(action: "replace-configuration", request: HelperRequest(id: profile.id, configuration: text))
                if let state = response.runtime { runtime[profile.id] = state }
                else { runtime.removeValue(forKey: profile.id) }
            }
        }
        catch {
            let failure = error
            // A client deadline/disconnect does not prove the root operation
            // stopped. Do not roll back storage underneath an in-flight update.
            if failure is ServiceOperationError { throw failure }
            do {
                if let previousText { try SecureStore.save(previousText, id: profile.id) }
                else { try SecureStore.delete(profile.id) }
                try persist(previousProfiles)
            } catch {
                throw DeckError.message("The update failed and saved settings could not be fully restored. Check Keychain access and this tunnel before retrying.")
            }
            throw failure
        }
        selection = profile.id
    }

    func remove(_ profile: TunnelProfile) {
        guard runtime[profile.id] == nil, onDemand[profile.id]?.settings.enabled != true, busy == nil else { return }
        do {
            let oldText = try SecureStore.read(profile.id)
            try SecureStore.delete(profile.id)
            do { try persist(profiles.filter { $0.id != profile.id }) }
            catch { try? SecureStore.save(oldText, id: profile.id); throw error }
            selection = profiles.first?.id
        } catch { self.error = error.localizedDescription }
    }

    func refresh() {
        var demand: [UUID: OnDemandStatus] = [:]
        var fresh: [UUID: TunnelRuntime] = [:]
        for profile in profiles {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: OnDemandStatus.statusPath(owner: getuid(), id: profile.id))),
               let status = try? JSONDecoder().decode(OnDemandStatus.self, from: data), status.id == profile.id, status.owner == getuid() {
                demand[profile.id] = status
            }
            let path = "/var/run/tunneldeck/\(getuid())/\(profile.interfaceName).json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   var state = try? JSONDecoder().decode(TunnelRuntime.self, from: data), state.id == profile.id,
                   state.owner == getuid(), FileManager.default.fileExists(atPath: "/var/run/wireguard/\(state.interface).sock") else { continue }
            if let existing = runtime[profile.id], existing.connectedAt == state.connectedAt {
                state.peers = existing.peers
                state.sampledAt = existing.sampledAt
            }
            fresh[profile.id] = state
        }
        if !serviceReady { runtime = fresh }
        onDemand = demand
    }

    func refreshFromService() {
        guard !refreshingService, busy == nil, !installingService else { return }
        refreshingService = true
        let ids = profiles.map(\.id)
        Task {
            defer { refreshingService = false }
            do {
                let result = try await PrivilegedClient.call(action: "status", request: HelperRequest(id: UUID(), ids: ids))
                serviceReady = true
                // A control operation started while we were awaiting this sample:
                // do not overwrite its newer state with an earlier sample.
                if busy == nil { runtime = Dictionary((result.runtimes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }) }
            } catch { serviceReady = false }
        }
    }

    func installService() {
        guard !installingService, busy == nil else { return }
        installingService = true
        Task {
            defer { installingService = false; refresh(); refreshFromService() }
            do {
                try await PrivilegedClient.install()
                _ = try await PrivilegedClient.call(action: "ping", request: HelperRequest(id: UUID()))
                serviceReady = true
            } catch { self.error = error.localizedDescription }
        }
    }

    func toggle(_ profile: TunnelProfile) {
        guard busy == nil, !installingService else { return }
        refresh()
        let connected = runtime[profile.id] != nil
        do {
            let text = connected ? nil : try SecureStore.read(profile.id)
            if let text {
                let config = try WireGuardConfiguration(text: text)
                for other in profiles where other.id != profile.id && runtime[other.id] != nil {
                    let otherConfig = try WireGuardConfiguration(text: SecureStore.read(other.id))
                    guard !config.conflicts(with: otherConfig) else {
                        throw DeckError.message("This tunnel overlaps with “\(other.name)”. Disconnect it or edit the routes first.")
                    }
                }
            }
            let disable = connected && onDemand[profile.id]?.settings.enabled == true ? OnDemandSettings(enabled: false) : nil
            perform(profile, action: connected ? "down" : "up", text: text, settings: disable)
        } catch { self.error = error.localizedDescription }
    }

    func statistics(_ profile: TunnelProfile) {
        guard busy == nil, runtime[profile.id] != nil else { return }
        perform(profile, action: "stats", text: nil)
    }

    func repairRoutes(_ profile: TunnelProfile) {
        guard busy == nil, !installingService, runtime[profile.id] != nil else { return }
        perform(profile, action: "repair-routes", text: nil)
    }

    func configureOnDemand(_ profile: TunnelProfile, settings: OnDemandSettings) {
        guard busy == nil else { return }
        do {
            try settings.validate()
            let text = settings.enabled ? try SecureStore.read(profile.id) : nil
            perform(profile, action: "on-demand", text: text, settings: settings)
        } catch { self.error = error.localizedDescription }
    }

    private func perform(_ profile: TunnelProfile, action: String, text: String?, settings: OnDemandSettings? = nil) {
        busy = profile.id
        Task {
            defer { busy = nil; refresh(); refreshFromService() }
            do {
                let response = try await PrivilegedClient.perform(action: action, request: HelperRequest(id: profile.id, configuration: text, onDemand: settings))
                if let state = response.runtime { runtime[profile.id] = state }
                else if action == "down" { runtime.removeValue(forKey: profile.id) }
            } catch { self.error = error.localizedDescription }
        }
    }
}
