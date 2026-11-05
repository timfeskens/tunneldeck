import SwiftUI
import AppKit
import TunnelDeckCore

@main
struct TunnelDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TunnelStore()

    init() {
        if CommandLine.arguments.contains("--check-service") {
            Task { @MainActor in
                do {
                    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    let url = directory.appendingPathComponent("TunnelDeck/profiles.json")
                    let profiles = try JSONDecoder().decode([TunnelDeckCore.TunnelProfile].self, from: Data(contentsOf: url))
                    let response = try await PrivilegedClient.call(action: "status", request: TunnelDeckCore.HelperRequest(id: UUID(), ids: profiles.map(\.id)))
                    let summary: [String: Any] = ["service": "ready", "profiles": profiles.count, "activeTunnels": response.runtimes?.count ?? 0,
                                                   "sampledTunnels": response.runtimes?.filter { $0.sampledAt != nil }.count ?? 0,
                                                   "healthyRoutes": response.runtimes?.filter { $0.routeHealth?.healthy == true }.count ?? 0,
                                                   "routingWarnings": response.runtimes?.filter { $0.routeHealth?.healthy == false }.count ?? 0]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: .sortedKeys), as: UTF8.self))
                    exit(0)
                } catch {
                    print("Service check failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup("TunnelDeck", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 680, minHeight: 440)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 760, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuContents(store: store)
        } label: {
            Image(systemName: store.connectedCount > 0 ? "checkmark.shield.fill" : "network")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: TunnelStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard store.busy == nil, !store.installingService else { NSSound.beep(); return .terminateCancel }
        store.refresh()
        guard store.connectedCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Leave tunnels connected?"
        alert.informativeText = "Quitting does not disconnect your tunnels. Enabled on-demand rules keep running in the background. Reopen TunnelDeck to manage them."
        alert.addButton(withTitle: "Quit and Leave Connected")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct MenuContents: View {
    @ObservedObject var store: TunnelStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("TunnelDeck")
        if store.profiles.isEmpty { Text("No tunnels added") }
        ForEach(store.profiles) { profile in
            Button {
                store.toggle(profile)
            } label: {
                Label(profile.name + " — " + store.statusTitle(profile.id), systemImage: store.runtime[profile.id] == nil ? "circle" : store.runtime[profile.id]?.routeHealth?.healthy == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            }
            .disabled(store.busy != nil || !store.dependencies.missing.isEmpty)
        }
        Divider()
        Button("Manage Tunnels…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit TunnelDeck") {
            NSApp.terminate(nil)
        }
        .disabled(store.busy != nil)
    }
}
