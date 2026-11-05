# TunnelDeck

A native macOS app for running multiple WireGuard split tunnels at the same time.
Manage independent connections from a simple tunnel list or the menu bar—without
switching one profile off to connect another.

**Apple Silicon · macOS 14+ · Early release**

[Download the latest DMG](https://github.com/timfeskens/tunneldeck/releases/latest)
· [Report a bug](https://github.com/timfeskens/tunneldeck/issues)
· [Security](SECURITY.md)

TunnelDeck is a client for your existing WireGuard configurations, not a VPN
provider. It requires no TunnelDeck account and has no telemetry or cloud service.
It is an independent project, not affiliated with the WireGuard project.

## Features

- **Simultaneous tunnels** with independent connect/disconnect controls for disjoint networks.
- **Native SwiftUI interface** with connection details and per-tunnel menu-bar toggles.
- **File and ZIP import** for WireGuard configurations, including official-app exports.
- **On-demand activation** for Wi-Fi, Ethernet, or both, with optional Wi-Fi network rules.
- **Automatic status updates** for routes, handshake timestamps, and transfer counters.
- **Explicit route repair** that never silently replaces another interface's routes.
- **Keychain storage** for imported configurations and hidden-by-default keys.
- **Bundled runtime**—release downloads do not require Homebrew.

## Install

1. Download **`TunnelDeck-<version>-arm64.dmg`** from [Releases](https://github.com/timfeskens/tunneldeck/releases/latest).
2. Open the DMG and drag **TunnelDeck.app → Applications**.
3. Eject the image and open TunnelDeck from Applications.
4. Click **Install / Update…** and approve the administrator prompt to install the root service.
5. Import a WireGuard `.conf` file or exported `.zip`, then connect a tunnel.

> **Signing notice:** current releases are ad-hoc signed, **not Developer ID signed
> or notarized**. If macOS blocks launch, review **System Settings → Privacy &
> Security → Open Anyway** only for a download you trust. Do not disable Gatekeeper
> globally. TunnelDeck is early, unaudited software; review the limits below before use.

Only **Apple Silicon (M-series) Macs** are supported. Intel builds are not provided.
Release assets include `SHA256SUMS.txt` and corresponding source archives. To check
a downloaded DMG, run this in the folder containing it and the checksum file:

```sh
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```

Checksums detect corruption; they do not establish publisher identity.

### Updating

Quit TunnelDeck using **Quit and Leave Connected**, replace the app in Applications,
then reopen it and approve **Install / Update…**. Updates do not intentionally
restart active tunnels. There is no automatic updater. Do not delete installed
runtime directories while tunnels are active; background route monitors may use them.

## Using tunnels

Use **+ → Import from File or ZIP…**, review the imported profiles, and connect.
Connecting another tunnel leaves existing TunnelDeck tunnels running. Profiles
can be edited or removed only while disconnected.

**Quitting the app leaves tunnels connected.** Reopen it to manage them. Interfaces
do not survive a reboot unless an enabled on-demand rule reconnects them.

### Migrating from another WireGuard app

Before connecting an imported profile, deactivate its old copy **and disable its
on-demand rule** in the other app. Never activate the same client keys/profile in
two apps at once. Different profiles can coexist when their routes and interface
networks do not conflict. TunnelDeck cannot control another app's on-demand rules.

### On-demand activation

Select a tunnel and open **Activate on demand → Configure…**. Choose Wi-Fi,
Ethernet, or both. Wi-Fi rules support any network, only listed networks, or all
except listed networks; SSIDs are exact and case-sensitive.

- Rules run through the root service, including while the app is closed and after reboot.
- **Disconnect** also disables that tunnel's on-demand rule.
- Turning a rule off in settings leaves an active tunnel connected.
- macOS may withhold Wi-Fi names from background services. SSID-specific rules
  fail closed when the name is unavailable; **Any network** does not need SSID access.
- Enabled configurations are also stored in root-only persistent files so the
  service can reconnect while your login Keychain is locked. Disabling a rule
  removes its persistent configuration copy.

On-demand activation is not a kill switch, internet-reachability check, or
handshake watchdog.

### Route warnings

An interface being up does not prove that traffic reaches its destination.
TunnelDeck checks for missing/conflicting routes and duplicate interface addresses
and displays warnings rather than treating them as healthy connections.

If another VPN removed routes during disconnect, deactivate that profile and its
on-demand rule, then use **Repair Routes…**. Repair explicitly adds missing routes
to the existing interface; it refuses competing conflicts and never deletes or
replaces another interface's route. Background status checks do not change routes.

## Important limits

- **Split tunnels only.** Default (`/0`) routes are rejected. This is not a
  full-tunnel VPN or kill switch; do not use broad routes to bypass that limit.
- **System DNS is preserved.** Imported `DNS` values are not applied. Private
  names need an existing resolver that can answer them; scoped DNS is not implemented.
- **Disjoint networks required.** Overlapping routes/interface networks between
  TunnelDeck tunnels are blocked. Other VPNs and local network routes may also conflict.
- **IPv4-preferred hostname endpoints.** Names are resolved again on connection
  and reconnect. IPv6-only names and explicit IPv6 endpoints remain supported.
  This is not application-health failover or automatic MTU discovery.
- **Not a System Settings VPN extension.** Tunnels are managed by command-line
  WireGuard tools, not Apple's NetworkExtension framework, and do not appear in
  **System Settings → VPN**.
- No key generation, configuration export, QR-code import, or custom configuration hooks.
- No production security audit. Handshakes and route health do not prove
  application reachability or traffic isolation under every network condition.

## Security and permissions

The app runs as your normal user. Administrator approval installs a persistent,
root-owned helper and LaunchDaemon; routine operations use authenticated XPC
without repeated password prompts. There is no sudoers rule or network listener.
Rebuilt ad-hoc apps require another approved service update to enroll their new signature.

Configurations are stored in the macOS Keychain. Active tunnels also require
root-only runtime configuration files; enabled on-demand rules require root-only
persistent copies. Configuration hooks and unsafe directives are rejected again
by the helper. Raw WireGuard output containing keys is not displayed or logged.

Release tools are hash-checked and copied into root-owned, content-addressed
directories. Source-only development builds use trusted Homebrew tools instead.
You must trust the app and its dependencies; hashes and ad-hoc signatures are not
a substitute for a security audit. See [SECURITY.md](SECURITY.md) before reporting
a vulnerability, and never include real keys or configuration exports in an issue.

## Development

Requires Apple Silicon and Xcode / Swift 6. A source-only build uses Homebrew:

```sh
git clone https://github.com/timfeskens/tunneldeck.git
cd tunneldeck
brew install wireguard-tools wireguard-go bash
bash scripts/build.sh
open dist/TunnelDeck.app
```

The script assembles and ad-hoc signs the app and embedded helper. It does not
install the service, copy the app to Applications, or change network settings.
`swift run` alone does not assemble the helper bundle.

- `Sources/TunnelDeck`: SwiftUI app, Keychain storage, and service client.
- `Sources/TunnelDeckCore`: configuration validation, ZIP import, routing models, and endpoint resolution.
- `Sources/TunnelDeckHelper`: privileged service, installer, and WireGuard runner.
- `scripts/`: app/runtime builds, DMG packaging, verification, and icon generation.

The unit-test suite is maintained locally and is not included in this repository.
CI builds a fresh checkout; release CI also verifies the packaged DMG. Live VPN
testing requires explicit test profiles and an independent recovery connection.
See [release build instructions](docs/DEVELOPMENT.md) for standalone builds and diagnostics.

## License

TunnelDeck source and original icon artwork are [MIT licensed](LICENSE).
Release DMGs bundle separate Bash and WireGuard programs with their own licenses.
License notices and corresponding source archives accompany each release and are
included in the DMG. See [THIRD_PARTY.md](THIRD_PARTY.md) for details.
