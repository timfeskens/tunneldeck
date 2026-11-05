# TunnelDeck

A small, open-source macOS WireGuard interface. A tunnel list, connection details,
and independent Connect/Disconnect buttons—without the official macOS app's
one-active-profile restriction.

**Early release.** Apple Silicon (M-series), macOS 14 or newer; Intel is not supported.
No VPN provider account, server changes, telemetry, or cloud service.

## Download and install

Get the **arm64 DMG** from [GitHub Releases](https://github.com/timfeskens/tunneldeck/releases).
The repository is currently private; downloads require an authorized GitHub account.

1. Open the DMG and drag **TunnelDeck.app → Applications**.
2. Eject the image and launch the installed app.
3. These first builds are **ad-hoc signed, not notarized**. If macOS blocks launch,
   review **System Settings → Privacy & Security → Open Anyway** only for a
   download you trust. Do not globally disable Gatekeeper.
4. Approve **Install / Update…** once to install the root service.

Release DMGs bundle their WireGuard runtime—**no Homebrew required**. The approved
installer verifies the bundled file hashes and installs root-owned,
content-addressed runtime copies. Existing copies are not overwritten while
background route monitors may use them. Updates require one approved service
update; the app does not automatically update itself. See [installation notes](docs/INSTALL.txt).

## Build and launch from source

Xcode / Swift 6 required. Source builds use Homebrew by default:

```sh
brew install wireguard-tools wireguard-go bash
swift test
bash scripts/build.sh
open dist/TunnelDeck.app
```

The build script produces an ad-hoc-signed, native-architecture
app, with its helper embedded. `swift run` alone does not assemble the helper
bundle. Public binary distribution would additionally require a Developer ID,
hardened runtime review, notarization, and release testing. The build script
does **not** install packages, copy the app to Applications, or change VPNs.

## Release workflow

Push a version tag matching `CFBundleShortVersionString` (for example `v0.6.1`).
`.github/workflows/release.yml` builds on an Apple Silicon macOS runner, builds
pinned standalone runtime tools from source, signs ad hoc, creates an arm64 DMG,
mounts and verifies it, and publishes a GitHub Release **only after verification**.
The workflow can also be dispatched for an existing tag. No signing secrets are
needed for these early builds; Developer ID signing/notarization remains follow-up work.

Assets include the DMG, SHA-256 checksums, TunnelDeck source, and corresponding
runtime source with Go dependencies vendored. The source archives and notices
are also inside the DMG; see [third-party notices](THIRD_PARTY.md). To reproduce
the release locally with a working Go 1.26 toolchain:

```sh
BUNDLE_RUNTIME=1 bash scripts/build.sh
git archive --format=tar.gz --prefix=TunnelDeck/ -o dist/TunnelDeck-0.6.1-source.tar.gz HEAD
bash scripts/package-dmg.sh
bash scripts/verify-dmg.sh dist/TunnelDeck-0.6.1-arm64.dmg
```

Local tests stay ignored by Git by request. CI builds the source checkout and
release smoke checks; it cannot run the untracked local unit-test suite.

## Use

1. Click **+ → Import from File or ZIP…** and select a WireGuard `.conf` file or
   the `.zip` archive exported by the official WireGuard app.
2. For a single file, give the tunnel a name and save. For an archive, review the
   tunnel names and click **Import All**. Keys are hidden unless you reveal them.
3. Click **Install / Update…** in the root-service banner and approve once.
   Routine Connect/Disconnect and statistics refresh then use the service without
   further password prompts. Clicking Connect before setup also offers installation.
4. Import and connect another profile; the first one stays connected.

The menu bar also has a toggle for each tunnel. You can edit/remove a profile
only while disconnected. **Quitting leaves active tunnels connected**; reopen
the app to disconnect. Interfaces do not survive a reboot, and this version
does not automatically connect unless you explicitly enable on-demand below.

### Activate on demand

Select a tunnel, then **Activate on demand → Configure…**. Enable automatic
activation and choose **Wi-Fi**, **Ethernet**, or both. Wi-Fi supports **Any
network**, **Only these networks**, and **Except these networks**, with exact,
case-sensitive SSID names entered one per line.

After one-time root-service installation, saving rules needs no password. The
root-owned helper and system LaunchDaemon evaluate the primary physical
network every five seconds, independently manages each tunnel, reconnects after
physical network changes (including re-resolving the endpoint), and retries
failed starts every 30 seconds. It keeps working with the window/app closed and
after reboot. This is not Apple's NetworkExtension on-demand engine, an
internet-reachability check, a handshake watchdog, or a kill switch.

- **Disconnect** also turns off that tunnel's on-demand setting. Other tunnels
  and their on-demand settings are not disabled.
- Turning on-demand **off** in its settings leaves an active tunnel connected.
- Turn off on-demand and disconnect before editing/removing a profile. This
  avoids a saved automatic configuration becoming different from the editor.
- Modern macOS may hide SSIDs from background services. **Any network** does
  not need SSID access; **Only/Except** rules fail closed if the name is unavailable,
  with an explanation shown in the tunnel details. A mixed Ethernet rule can
  still match Ethernet. SSID-specific operation is not guaranteed on every OS.
- The enabled config is additionally persisted, root-owned and `0600`, in
  `/Library/Application Support/TunnelDeck/OnDemand/<uid>/`. It must be available
  to reconnect when your login Keychain is locked. Turning it off removes this
  copy. Rule names and non-secret status use `0644` files in the same directory.
- The installed executable is
  `/Library/Application Support/TunnelDeck/TunnelDeckHelper`; its job is
  `/Library/LaunchDaemons/codes.savvy.tunneldeck.service.plist`.
  Disabling the last rule removes its saved config, but keeps the root service
  available for manual tunnel controls. Use **Install / Update…** after rebuilding
  to enroll the new app signature. The previous on-demand-only job is migrated
  without intentionally disconnecting active interfaces.
- In System Settings, macOS may list it under **General → Login Items &
  Extensions**. Blocking background operation prevents automatic connections.

ZIP import reads all `.conf` entries in memory, including nested folders. Nothing
is extracted to disk or connected automatically. Existing profiles are never
replaced; duplicate tunnel names get a numbered suffix. All configurations must
pass the same split-tunnel validation before any are saved. Encrypted, damaged,
ZIP64, unsafe-path, and symlink archives are rejected. Limits: 16 MiB archive,
256 tunnels, 128 KiB per configuration, and 8 MiB total configuration data.

### Using it beside the official WireGuard app

You can leave an existing tunnel in the official app and manage a **different**
tunnel with TunnelDeck. For example: leave Savvy active in the official app,
import N150 into TunnelDeck, then connect N150 there. Do not activate the same
client keys/profile in both places. TunnelDeck cannot enumerate the official
app's private configurations or control its on-demand behavior. Activating
another profile *in the official app* can still disconnect its existing profile.

N150's `AllowedIPs = 192.168.68.74/32` and the Savvy routes discussed during
development are disjoint and do not need to be merged. Your exported configs,
not example keys or automatically extracted credentials, must be imported.

## Deliberate limits

- **Endpoint transport:** hostname endpoints are resolved on connection, preferring
  IPv4 when both IPv4 and IPv6 are available. IPv6-only hostnames and explicit IPv6
  endpoints remain supported. This avoids a reproduced dual-stack case where an
  IPv6 transport handshook but TLS traffic stalled. Only the root-owned runtime
  config gets the numeric endpoint; the imported hostname is retained in Keychain
  and resolved again on reconnect (including on-demand network changes). This is
  address-family preference, not automatic application-health failover. Explicit
  MTU values are preserved; path-MTU discovery is not implemented by TunnelDeck.
- **Split tunnels only.** `/0` default routes are rejected. This is not a
  full-tunnel VPN or kill switch; do not use broad routes to circumvent that limit.
- **Preserve system DNS.** Imported `DNS` values are shown but are never applied.
  This avoids competing `wg-quick` DNS restore/monitor processes. Private DNS
  names may not resolve unless your existing resolver can answer them. Scoped
  per-domain DNS is not implemented.
- **Overlapping routes/interface networks are blocked between TunnelDeck
  tunnels**, even where a more-specific-route setup could theoretically work.
  Other VPN apps' routes and pre-existing LAN routes are not fully analyzed;
  `wg-quick` may reject a conflicting route. A peer must not be reachable only
  through a route it is meant to create.
- **Status is not proof of a successful handshake.** Status, handshake
  timestamps, and transfer counters refresh automatically every three seconds
  through the root service. **Refresh** also requests an immediate sample. The
  UI never reads root-only WireGuard `.name` files directly. Before installation,
  non-secret runtime metadata/socket presence provide a best-effort fallback,
  labeled “Interface up — checking routes” rather than Active.
- **Route health is checked on every status refresh.** Duplicate interface
  addresses and routes owned by another interface show an orange warning, not a
  green Active state. Starting a profile is refused if another interface already
  uses the same address or owns overlapping equally/more-specific routes.
  Do not run the same client keys in the official app and TunnelDeck together.
- If a competing app removed routes when it disconnected, deactivate its copy
  **and its on-demand rule**, then click **Repair Routes…**. This explicitly adds
  missing AllowedIPs routes to the existing TunnelDeck interface without a
  restart. It refuses competing VPN/address conflicts and never deletes or
  replaces another interface's route. Partial progress is retained if a later
  addition fails; refresh and inspect before retrying. Background status checks
  never change routes. Route health is not an application-level connectivity test.
- No automatic config export, key generation, QR-code import, login-window app,
  subscriptions, custom scripts, or full-tunnel mode. The privileged background
  service is installed with explicit one-time administrator approval.
- CLI-managed tunnels do not appear in **System Settings → VPN**. Native
  NetworkExtension integration is deliberately not added at the expense of
  the simultaneous-tunnel requirement.

## Privilege and key handling

The SwiftUI app runs as your normal user. macOS administrator authorization
(`osascript` / `do shell script`) is used only to install/update a **root-owned
LaunchDaemon**. The app uses a privileged Mach/XPC service for routine operations;
there is no sudoers rule or TCP/Unix listening socket.

The installer enrolls your user ID and the app's designated code-signing
requirement in root-only `Clients/<uid>.json` records. XPC enforces that requirement
on messages, and the service derives ownership from the authenticated connection,
never a UID supplied in a request. The app checks the root-owned helper signature
and pins its connection to that requirement as well. Different users cannot
operate each other's tunnels. Local ad-hoc builds use a code-hash requirement;
rebuilding therefore requires one approved service update. This is unaudited
local-build software, not a production-certified privilege boundary.

- Configurations are kept in the **macOS Keychain**, not in the profile metadata.
- Non-secret profile metadata is stored with owner-only permissions in
  `~/Library/Application Support/TunnelDeck/profiles.json`.
- A temporary **installation** request uses a random `0700` directory and `0600`
  file, removed after approval. It contains no tunnel keys. Routine configs are
  passed through authenticated XPC, never command-line arguments.
  A process crash can leave a private request file in your macOS temporary folder;
  this is not a forensic secure-erasure guarantee.
- The helper validates the configuration **again**, generates clean `wg-quick`
  input, and rejects hooks, `SaveConfig`, `Table`, and unknown settings. It checks
  installation request ownership, file type, permissions, size, and symlinks.
  It limits XPC actions/payload sizes and derives file paths from validated IDs.
  A root-owned lock
  serializes operations. IDs, executable paths, and actions are not imported.
- While connected, `wg-quick` needs a **root-owned `0600` runtime configuration**
  at `/var/run/tunneldeck/<uid>/<interface-name>.conf`. It is removed on successful
  disconnect; `/var/run` is cleared at reboot. Public runtime metadata is stored
  alongside it so the app can rediscover connections without root polling.
- The app never requests `wg show ... dump` (which would include private keys).
  Raw dependency output is not displayed or logged; errors are intentionally
  generic. Redacted preview also hides comments.
- Homebrew's tools and Bash execute as root after approval. **Your Homebrew
  installation and this app bundle must be trusted.** This is not a sandbox
  boundary against code already running as your user, nor a replacement for
  auditing the dependencies. Do not use untrusted modified builds.
- To prevent Darwin `wg-quick` waiting indefinitely under launchd, the helper
  makes a root-owned runtime copy that removes only its final launchd `wait`.
  The original Homebrew script is not modified. An unrecognized script layout
  is rejected. Route-monitor cleanup still uses `wg-quick`'s own monitor.

Network operations may fail because of unreachable endpoints, conflicting routes,
invalid server/client keys, or macOS permissions. Failed disconnects preserve
runtime files for retry. If recovery is needed, the root-owned runtime config
can be used with `sudo /opt/homebrew/bin/wg-quick down <runtime-config-path>`
(Intel Homebrew may use `/usr/local/bin/wg-quick`). Do not manually delete active
runtime files or WireGuard sockets before attempting a normal disconnect.

## Development

```sh
swift test
swift build
bash scripts/build.sh
```

After approving service installation, a read-only diagnostic can check that the
actual signed app is authorized and can sample existing tunnels:

```sh
dist/TunnelDeck.app/Contents/MacOS/TunnelDeck --check-service
```

It prints only counts/service readiness, not keys, endpoints, or configurations;
it never installs the helper or connects/disconnects a tunnel.

- `TunnelDeckCore`: strict config parser, route overlap checks, shared models.
- ZIP import uses the system zlib for bounded decompression, not a third-party
  package or a shell extraction command.
- `TunnelDeck`: SwiftUI window/menu bar, Keychain storage, authorization client.
- `TunnelDeckHelper`: root service, XPC authentication, installer, and WireGuard runner.
- `Tests`: synthetic configs only; tests never create interfaces or change DNS.

`Tests/`, test results, and Xcode result bundles are intentionally ignored by Git
at the owner's request. Tests still run locally. The package and CI support a
fresh checkout without these local tests; CI skips that step when they are absent.

The tests cover parsing, IPv4/IPv6 overlap, N150/Savvy coexistence checks,
normalization, unsafe directives/inputs, serialization, quoting, stored/deflated
ZIPs, native macOS ZIP compatibility, archive safety limits, on-demand matching,
SSID privacy behavior, and backward-compatible requests. They do not
prove real VPN connectivity. Live multi-tunnel and authorization testing must be
done explicitly with non-production/test profiles and a recovery connection.

### App icon

Original icon artwork is included in `Resources/AppIcon.icns` and
`Resources/AppIcon.png`, under the same MIT license. Reproduce it with
`swift scripts/generate-icon.swift`. The build script regenerates it when its
source changes and includes the ICNS file in the app bundle.

## License

TunnelDeck source is **MIT**. WireGuard tools, wireguard-go, Bash, and any other
dependencies retain their own licenses; they are installed separately and are
not bundled or relicensed by this repository.
