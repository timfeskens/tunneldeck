import Foundation
import TunnelDeckCore

extension Helper {
    /// Called under OperationLock, which also excludes the on-demand loop.
    func replaceConfiguration() throws -> HelperResponse {
        guard let text = request.configuration else { throw DeckError.message("Missing replacement configuration.") }
        let configuration = try WireGuardConfiguration(text: text)
        let active = realInterface()
        let oldRuntime = active == nil ? nil : try readState()
        guard active == oldRuntime?.interface else { throw DeckError.message("Tunnel identity changed. No configuration was applied.") }
        let previousText = active == nil ? nil : try String(contentsOfFile: configPath, encoding: .utf8)
        let recordPath = OnDemandStatus.root + "/\(owner)/\(name).json"
        let record = manager.fileExists(atPath: recordPath) ? try OnDemandService.loadRecord(recordPath) : nil
        if let record {
            guard record.id == request.id, record.owner == owner else { throw DeckError.message("On-demand identity mismatch.") }
        }
        var disconnected = false
        var resolvedText = ""
        return try ConfigurationReplacement.run(prepare: {
            if active != nil {
                try validateConnection(configuration, excluding: active)
                // Do DNS resolution before taking the existing interface down.
                resolvedText = try configuration.runtimeText(resolvingEndpoints: EndpointResolver.resolve)
            }
        }, apply: {
            if active != nil { _ = try execute(action: "down"); disconnected = true }
            let resolved = Helper(owner: owner, request: HelperRequest(id: request.id, configuration: resolvedText))
            let result = active == nil ? HelperResponse(success: true, message: "Configuration updated.") : try resolved.execute(action: "up")
            if let record, record.settings.enabled {
                let rule = Helper(owner: owner, request: HelperRequest(id: request.id, configuration: text, onDemand: record.settings))
                _ = try OnDemandService.configure(helper: rule, settings: record.settings)
            }
            return result
        }, restore: {
            // If disconnect failed and the original interface still exists,
            // leave it alone; never tear down an unrelated or surviving tunnel.
            // Attempt each recovery step even if another fails: a status-file
            // error must not prevent restoring the old rule or connection.
            var recoveryFailed = false
            if disconnected, realInterface() != nil {
                do { _ = try execute(action: "down") }
                catch { recoveryFailed = true }
            }
            if let record {
                let rule = Helper(owner: owner, request: HelperRequest(id: request.id, configuration: record.configuration, onDemand: record.settings))
                do { _ = try OnDemandService.configure(helper: rule, settings: record.settings) }
                catch { recoveryFailed = true }
            }
            if let previousText, realInterface() == nil {
                do { _ = try Helper(owner: owner, request: HelperRequest(id: request.id, configuration: previousText)).execute(action: "up") }
                catch { recoveryFailed = true }
            }
            if recoveryFailed { throw DeckError.message("Recovery was incomplete.") }
        })
    }

    func validateConnection(_ configuration: WireGuardConfiguration, excluding interface: String?) throws {
        let routing = try RoutingSnapshot(helper: self)
        let duplicates = routing.duplicates(configuration: configuration, excluding: interface)
        let conflicts = RouteHealth(routes: configuration.routes, interface: interface ?? "", table: routing.table).issues.filter(\.conflict)
        guard duplicates.isEmpty, conflicts.isEmpty else {
            throw DeckError.message("Another interface uses this VPN address or owns overlapping routes. No interfaces were changed.")
        }
        let enumerator = manager.enumerator(atPath: "/var/run/tunneldeck")
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix(".json") else { continue }
            let url = URL(fileURLWithPath: "/var/run/tunneldeck/" + relative)
            guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(TunnelRuntime.self, from: data),
                  state.id != request.id, manager.fileExists(atPath: "/var/run/wireguard/\(state.interface).sock") else { continue }
            let other = try WireGuardConfiguration(text: String(contentsOf: url.deletingPathExtension().appendingPathExtension("conf"), encoding: .utf8))
            guard !configuration.conflicts(with: other) else {
                throw DeckError.message("Routes or interface networks overlap with another TunnelDeck tunnel. No interfaces were changed.")
            }
        }
    }
}
