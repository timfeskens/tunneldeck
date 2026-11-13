import Foundation
import TunnelDeckCore

/// Accessed only while holding OperationLock, including manual retry/status.
enum RouteRecovery {
    struct Key: Hashable {
        let owner: UInt32
        let id: UUID
    }

    struct Episode {
        let connectedAt: Date
        var budget = RecoveryBudget()
        var status: RouteRecoveryStatus?
    }

    static var episodes: [Key: Episode] = [:]
    static var activations: [Key: RecoveryBudget] = [:]
    static var network: NetworkSnapshot?
    static var networkChangedAt = Date()

    static func status(for state: TunnelRuntime) -> RouteRecoveryStatus? {
        let episode = episodes[Key(owner: state.owner, id: state.id)]
        return episode?.connectedAt == state.connectedAt ? episode?.status : nil
    }

    static func reset(owner: UInt32, id: UUID) {
        episodes.removeValue(forKey: Key(owner: owner, id: id))
        activations.removeValue(forKey: Key(owner: owner, id: id))
    }

    static func claimActivation(owner: UInt32, id: UUID, now: Date = Date()) -> Bool {
        let key = Key(owner: owner, id: id)
        var budget = activations[key] ?? RecoveryBudget(now: now)
        let allowed = budget.takeAttempt(now: now)
        activations[key] = budget
        return allowed
    }

    static func activationMessage(owner: UInt32, id: UUID) -> String {
        let budget = activations[Key(owner: owner, id: id)]
        return budget?.exhausted == true
            ? "Automatic connection stopped after 3 attempts. Connect manually to try again."
            : "Waiting to retry connection (\(budget?.attempts ?? 0)/3 attempts used)."
    }

    static func run(snapshot: NetworkSnapshot, now: Date = Date()) {
        if network != snapshot {
            network = snapshot
            networkChangedAt = now
            episodes.removeAll()
            activations.removeAll()
        }
        guard snapshot.reachable, now.timeIntervalSince(networkChangedAt) >= 5 else { return }
        var present = Set<Key>()
        let manager = FileManager.default
        let enumerator = manager.enumerator(atPath: "/var/run/tunneldeck")
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix(".json"),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: "/var/run/tunneldeck/" + relative)),
                  let state = try? JSONDecoder().decode(TunnelRuntime.self, from: data), state.owner > 0,
                  relative == "\(state.owner)/\(TunnelProfile.interfaceName(for: state.id)).json" else { continue }
            let helper = Helper(owner: state.owner, request: HelperRequest(id: state.id))
            guard helper.realInterface() == state.interface else { continue }
            let key = Key(owner: state.owner, id: state.id)
            present.insert(key)
            var episode = episodes[key].flatMap { $0.connectedAt == state.connectedAt ? $0 : nil }
                ?? Episode(connectedAt: state.connectedAt, budget: RecoveryBudget(now: now))
            defer { episodes[key] = episode }
            do {
                let inspected = try helper.inspect(state)
                guard let health = inspected.routeHealth, !health.healthy else {
                    // Keep the budget for this network/connection even after
                    // success: flapping routes must not cause endless repairs.
                    episode.status = nil
                    continue
                }
                guard health.duplicateInterfaces.isEmpty, !health.issues.contains(where: \.conflict) else {
                    episode.status = RouteRecoveryStatus(attempts: episode.budget.attempts, exhausted: false,
                        message: "Automatic recovery is blocked by a conflicting interface. No routes were changed.")
                    continue
                }
                if episode.budget.takeAttempt(now: now) {
                    do {
                        _ = try helper.repairRoutes()
                        episode.status = nil
                        continue
                    } catch { /* Report sanitized bounded recovery state below. */ }
                }
                episode.status = RouteRecoveryStatus(attempts: episode.budget.attempts, exhausted: episode.budget.exhausted,
                    message: episode.budget.exhausted
                        ? "Automatic route recovery stopped after 3 attempts. Choose Retry Connection to try again, or Disconnect."
                        : "Waiting to retry missing routes (\(episode.budget.attempts)/3 attempts used).")
            } catch {
                // An inspection error must also consume a bounded attempt;
                // otherwise a broken configuration could be retried forever.
                _ = episode.budget.takeAttempt(now: now)
                episode.status = RouteRecoveryStatus(attempts: episode.budget.attempts, exhausted: episode.budget.exhausted,
                    message: episode.budget.exhausted ? "Automatic recovery stopped after 3 attempts. Choose Retry Connection to try again."
                        : "Cannot inspect this tunnel yet. Automatic recovery is waiting to retry.")
            }
        }
        episodes = episodes.filter { present.contains($0.key) }
    }
}
