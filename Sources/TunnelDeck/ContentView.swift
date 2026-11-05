import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TunnelDeckCore

private struct EditorDraft: Identifiable {
    let id = UUID()
    var profile: TunnelProfile?
    var name: String
    var text: String
}

private struct ArchiveDraft: Identifiable {
    let id = UUID()
    let tunnels: [ImportedTunnel]
}

struct ContentView: View {
    @ObservedObject var store: TunnelStore
    @State private var draft: EditorDraft?
    @State private var removing = false
    @State private var archive: ArchiveDraft?
    @State private var importing = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $store.selection) {
                    ForEach(store.profiles) { profile in
                        HStack(spacing: 9) {
                            Circle().fill(Color(nsColor: store.statusColor(profile.id))).frame(width: 8, height: 8)
                            Text(profile.name).lineLimit(1)
                            Spacer()
                            if store.busy == profile.id { ProgressView().controlSize(.small) }
                        }
                        .padding(.vertical, 4)
                        .tag(profile.id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Menu {
                        Button("Import from File or ZIP…", action: importFile)
                        Button("Add Empty Tunnel…") { draft = EditorDraft(name: "", text: "[Interface]\nPrivateKey = \nAddress = \n\n[Peer]\nPublicKey = \nAllowedIPs = \nEndpoint = \n") }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add tunnel")
                    Button { removing = true } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(store.selected == nil || store.selected.map { store.runtime[$0.id] != nil || store.onDemand[$0.id]?.settings.enabled == true } == true || store.busy != nil)
                        .help("Remove tunnel")
                    Spacer()
                }
                .disabled(store.busy != nil || importing)
                .padding(12)
            }
            .navigationTitle("Tunnels")
            .navigationSplitViewColumnWidth(min: 185, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if !store.serviceReady {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Root service setup").font(.headline)
                            Text("Approve once for password-free controls and automatic live statistics.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.installingService { ProgressView().controlSize(.small) }
                        Button("Install / Update…") { store.installService() }
                            .disabled(store.installingService || store.busy != nil)
                    }.padding().background(.quaternary)
                    Divider()
                }
                if !store.dependencies.missing.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Install WireGuard dependencies").font(.headline)
                        Text("brew install wireguard-tools wireguard-go bash").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("Missing: " + store.dependencies.missing.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding().background(.yellow.opacity(0.1))
                    Divider()
                }
                if let profile = store.selected {
                    TunnelDetails(store: store, profile: profile) {
                        do { draft = EditorDraft(profile: profile, name: profile.name, text: try store.configuration(for: profile)) }
                        catch { store.error = error.localizedDescription }
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Tunnel Selected", systemImage: "network")
                    } description: {
                        Text("Import a WireGuard configuration to get started.\nMultiple split tunnels can stay connected together.")
                    } actions: { Button("Import Tunnel…", action: importFile) }
                }
            }
            .navigationTitle(store.selected?.name ?? "TunnelDeck")
        }
        .sheet(item: $draft) { draft in
            TunnelEditor(store: store, profile: draft.profile, name: draft.name, text: draft.text)
        }
        .sheet(item: $archive) { archive in
            ArchiveConfirmation(store: store, tunnels: archive.tunnels)
        }
        .overlay {
            if importing { ProgressView("Reading tunnels…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .alert("TunnelDeck", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog("Remove “\(store.selected?.name ?? "")”?", isPresented: $removing) {
            Button("Remove Tunnel", role: .destructive) { if let profile = store.selected { store.remove(profile) } }
        } message: { Text("Its saved configuration will also be removed from Keychain. The original imported file is not changed.") }
    }

    private func importFile() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.title = "Import WireGuard Configuration or ZIP Export"
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText, .zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task { @MainActor in
            defer { importing = false }
            do {
                let tunnels = try await Task.detached(priority: .userInitiated) { try ArchiveImport.read(url: url) }.value
                if url.pathExtension.lowercased() == "zip" { archive = ArchiveDraft(tunnels: tunnels) }
                else if let tunnel = tunnels.first { draft = EditorDraft(name: tunnel.name, text: tunnel.text) }
            } catch { store.error = (error as? DeckError)?.localizedDescription ?? "The selected file could not be read." }
        }
    }
}

private struct ArchiveConfirmation: View {
    @ObservedObject var store: TunnelStore
    let tunnels: [ImportedTunnel]
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import \(tunnels.count) \(tunnels.count == 1 ? "Tunnel" : "Tunnels")").font(.headline)
            List(Array(tunnels.enumerated()), id: \.offset) { _, tunnel in
                Label(tunnel.name, systemImage: "network")
            }
            Text("Existing tunnels are kept. Duplicate names get a number. Imported tunnels will stay disconnected; DNS settings are not applied.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import All") {
                    do { try store.importTunnels(tunnels); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 440, height: 350)
    }
}

private struct TunnelDetails: View {
    @ObservedObject var store: TunnelStore
    let profile: TunnelProfile
    let edit: () -> Void
    @State private var showOnDemand = false
    @State private var confirmRepair = false
    var state: TunnelRuntime? { store.runtime[profile.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(profile.name).font(.title2.weight(.semibold))
                        Label(store.busy == profile.id ? "Working…" : store.statusTitle(profile.id), systemImage: state == nil ? "circle" : state?.routeHealth?.healthy == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(nsColor: store.statusColor(profile.id)))
                    }
                    Spacer()
                    Button(state == nil ? "Connect" : "Disconnect") { store.toggle(profile) }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.busy != nil || store.installingService || !store.dependencies.missing.isEmpty)
                }
                if let health = state?.routeHealth, !health.healthy {
                    VStack(alignment: .leading, spacing: 8) {
                        if !health.duplicateInterfaces.isEmpty {
                            Text("This VPN address is also active on \(health.duplicateInterfaces.joined(separator: ", ")). Deactivate the duplicate profile and its on-demand rule in the other VPN app.")
                        }
                        if !health.issues.isEmpty {
                            Text("\(health.issues.count) configured route(s) do not use this tunnel.")
                            ForEach(Array(health.issues.prefix(5).enumerated()), id: \.offset) { _, issue in
                                Text("\(issue.network) → \(issue.actualInterface ?? "no route")")
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        Text("After the other VPN is deactivated, use Repair Routes. TunnelDeck will not take routes away from another VPN automatically.")
                        Button("Repair Routes…") { confirmRepair = true }
                            .disabled(store.busy != nil || store.installingService || !store.serviceReady)
                    }
                    .font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Activate on demand").font(.headline)
                        Text(store.onDemand[profile.id]?.settings.summary ?? "Off").font(.callout).foregroundStyle(.secondary)
                        if let status = store.onDemand[profile.id], status.settings.enabled {
                            Text(status.message).font(.caption).foregroundStyle(.secondary)
                            Text("Disconnecting manually also turns off on-demand.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Configure…") { showOnDemand = true }.disabled(store.busy != nil)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                    detail("Addresses", profile.addresses.joined(separator: ", "))
                    detail("Endpoints", profile.endpoints.isEmpty ? "Not specified" : profile.endpoints.joined(separator: "\n"))
                    detail("DNS", "Keep current system DNS")
                    if !profile.configuredDNS.isEmpty { detail("Imported DNS", profile.configuredDNS.joined(separator: ", ") + " (not applied)") }
                    if let state {
                        detail("Interface", state.interface)
                        detail("Connected", state.connectedAt.formatted(date: .omitted, time: .shortened))
                    }
                    detail("Allowed IPs", profile.routes.joined(separator: "\n"))
                }
                .font(.callout)
                if let state {
                    Divider()
                    HStack {
                        Text("Peer statistics").font(.headline)
                        Spacer()
                        Button("Refresh") { store.statistics(profile) }.disabled(store.busy != nil || store.installingService)
                    }
                    if let sampled = state.sampledAt {
                        ForEach(Array(state.peers.enumerated()), id: \.offset) { _, peer in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(peer.endpoint).font(.system(.caption, design: .monospaced))
                                Text("Handshake: " + (peer.latestHandshake == 0 ? "Never" : Date(timeIntervalSince1970: TimeInterval(peer.latestHandshake)).formatted(date: .abbreviated, time: .standard)))
                                Text("Received: \(bytes(peer.received))  ·  Sent: \(bytes(peer.sent))")
                            }.font(.caption).textSelection(.enabled)
                        }
                        Text("Sampled \(sampled.formatted(date: .omitted, time: .standard)). Routes and statistics refresh automatically. Route checks do not prove a successful handshake or application reachability.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("Install the root service to refresh handshake and traffic statistics automatically.").font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
                HStack {
                    Text("Other tunnels stay connected.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit…", action: edit).disabled(state != nil || store.onDemand[profile.id]?.settings.enabled == true || store.busy != nil)
                }
                Text("If this profile also exists in the official WireGuard app, leave that copy inactive. The official app can disconnect its own other tunnel when you activate a profile there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .sheet(isPresented: $showOnDemand) {
            OnDemandEditor(store: store, profile: profile, settings: store.onDemand[profile.id]?.settings ?? OnDemandSettings())
        }
        .confirmationDialog("Repair this tunnel’s routes?", isPresented: $confirmRepair) {
            Button("Repair Routes") { store.repairRoutes(profile) }
        } message: {
            Text("Deactivate the duplicate VPN in the other app first. Only missing routes will be added. Competing VPN routes will never be deleted or replaced. Neither tunnel will be restarted.")
        }
    }

    @ViewBuilder private func detail(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary) }
}

private struct OnDemandEditor: View {
    @ObservedObject var store: TunnelStore
    let profile: TunnelProfile
    @State var settings: OnDemandSettings
    @State private var ssids = ""
    @State private var validationError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activate on Demand").font(.headline)
            Text(profile.name).foregroundStyle(.secondary)
            Toggle("Activate automatically", isOn: $settings.enabled)
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Ethernet", isOn: $settings.ethernet)
                Toggle("Wi-Fi", isOn: $settings.wiFi)
                if settings.wiFi {
                    Picker("Networks", selection: $settings.wiFiRule) {
                        ForEach(WiFiRule.allCases, id: \.self) { rule in Text(rule.title).tag(rule) }
                    }
                    if settings.wiFiRule != .any {
                        Text("Wi-Fi network names (one per line)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $ssids).font(.system(.body, design: .monospaced))
                            .frame(height: 80).border(.separator).disableAutocorrection(true)
                        Text("SSID rules need macOS to expose the Wi-Fi name to the background helper. If it is unavailable, the tunnel will not connect on Wi-Fi; use Any network instead.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.disabled(!settings.enabled)
            Text("The root service connects on matching networks, disconnects on others, and retries after network changes—even when TunnelDeck is closed. Service installation needs approval once; changing these rules does not. Turning this option off leaves an active tunnel connected.")
                .font(.caption).foregroundStyle(.secondary)
            if let validationError { Text(validationError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    settings.ssids = ssids.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    do {
                        try settings.validate()
                        store.configureOnDemand(profile, settings: settings)
                        dismiss()
                    } catch { validationError = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { ssids = settings.ssids.joined(separator: "\n") }
    }
}

private struct TunnelEditor: View {
    @ObservedObject var store: TunnelStore
    let profile: TunnelProfile?
    @State var name: String
    @State var text: String
    @State private var revealed = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(profile == nil ? "Add Tunnel" : "Edit Tunnel").font(.headline)
            TextField("Name", text: $name)
            HStack {
                Text("Configuration").foregroundStyle(.secondary)
                Spacer()
                Toggle("Reveal keys to edit", isOn: $revealed).toggleStyle(.checkbox)
            }
            if revealed {
                TextEditor(text: $text).font(.system(.body, design: .monospaced))
                    .disableAutocorrection(true).border(.separator)
            } else {
                ScrollView {
                    Text(redacted).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.background(.background).border(.separator)
            }
            Text("DNS is preserved, not overridden. Split tunnels only. Hooks and SaveConfig are rejected. Configurations are stored in your macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try store.save(name: name, text: text, editing: profile); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 580, height: 540)
    }

    private var redacted: String {
        text.components(separatedBy: .newlines).map { line in
            let key = line.components(separatedBy: "=")[0].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "privatekey" { return "PrivateKey = ••••••••" }
            if key == "presharedkey" { return "PresharedKey = ••••••••" }
            // Comments may also contain credentials supplied by the importer.
            return line.components(separatedBy: "#")[0]
        }.joined(separator: "\n")
    }
}
