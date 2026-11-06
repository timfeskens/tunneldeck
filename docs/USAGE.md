# TunnelDeck user guide

See the [README](../README.md#get-started) for installation and the signing notice.
TunnelDeck is early, unaudited software for Apple Silicon Macs running macOS 14+.

## Import and connect

Choose **+ → Import from File or ZIP…**, review the profiles, then connect.
WireGuard `.conf` files and ZIP exports are supported. Connecting another tunnel
leaves existing TunnelDeck tunnels running. Remove profiles only while disconnected.

## Edit a connected tunnel

Choose **Edit…** and authenticate with Touch ID or your Mac login password.
Connected tunnels use **Save & Reconnect**: saving briefly reconnects that tunnel
only. There is no save-for-later mode. Routes, addresses and endpoint resolution
are checked before disconnecting, and enabled on-demand rules receive the new
configuration under the same operation lock. Other tunnels are not restarted.
If applying the update fails, TunnelDeck attempts to restore the previous
configuration and connection and reports whether recovery succeeded. A restored
interface does not prove that the peer is reachable. If the service connection
times out, check status before retrying: the operation may still be running.

For disconnected tunnels, **Save** updates the configuration without connecting.
An enabled on-demand rule is updated too; it may subsequently connect when its
network rule matches.

### Touch ID and Keychain permissions

Editing existing configurations, revealing imported keys and exporting tunnels
use macOS authentication: Touch ID when available, with login-password fallback.
Routine statistics and the background on-demand loop do not request biometric
authentication. This is an app-level authentication gate, not a biometric access
control on each Keychain item.

Keychain entries trust the app explicitly, not all applications. Existing entries
are migrated in place after a successful read; macOS may request permission once
during migration. Ad-hoc signatures change between builds, so a future ad-hoc
update can still trigger Keychain permission dialogs. Touch ID does not override
those dialogs. Stable signing is needed to retain trust across builds.

Before migrating a profile from another app, deactivate its old copy **and disable
its on-demand rule**. Never activate the same client keys/profile in two apps at once.
Different profiles can coexist when their routes and interface networks do not conflict.
TunnelDeck cannot control another app's on-demand rules.

**Quitting the app leaves tunnels connected.** Reopen it to manage them. Interfaces
do not survive reboot unless an enabled on-demand rule reconnects them.

## Hide the window without quitting

Close the main window, or choose **Hide to Menu Bar** from the menu-bar menu or
the **Window** menu. TunnelDeck keeps running in the menu bar and disappears from
the Dock. Connections and automatic status updates continue normally.
Choose **Manage Tunnels…** in the menu bar to show the window and Dock icon again.
**Quit TunnelDeck** remains a separate action. Finish or cancel any open sheet
before using Hide to Menu Bar.

## Export selected tunnels

Choose **+ → Export Tunnels to ZIP…**, check the tunnels to include, then choose
**Export ZIP…** and a destination. **Select All** and **Deselect All** are available;
no tunnels are selected by default. Connected tunnels can also be exported without
disconnecting them. Exporting never changes configurations or connection state.

**The ZIP is unencrypted and includes private keys and any preshared keys.** Keep
it in a secure location and do not attach it to a public issue. The archive and
its staging file are written with owner-only permissions; copying it elsewhere,
cloud sync or a filesystem without Unix permissions can change that protection.
Exporting first requires Touch ID or your Mac login password, and macOS may also
request Keychain permission during migration or after an ad-hoc app update.

Each selected tunnel becomes one `.conf` file, compatible with TunnelDeck's ZIP
import and standard WireGuard tools. Unsafe filename characters are replaced;
duplicate filenames receive a number. Configurations are preserved in full,
including imported DNS values (which TunnelDeck does not apply). On-demand rules
and connection status are not included.

## On-demand activation

Select a tunnel and open **Activate on demand → Configure…**. Choose Wi-Fi,
Ethernet, or both. Wi-Fi supports any network, only listed networks, or all except
listed networks. SSIDs are exact and case-sensitive.

- Rules run through the root service while the app is closed and after reboot.
- **Disconnect** also disables that tunnel's on-demand rule.
- Turning a rule off in settings leaves an active tunnel connected.
- macOS may withhold Wi-Fi names from background services. SSID-specific rules
  fail closed when the name is unavailable; **Any network** does not need SSID access.
- Enabled configurations are also stored in root-only persistent files so the
  service can reconnect while your login Keychain is locked. Disabling a rule
  removes its persistent configuration copy.

On-demand activation is not a kill switch, internet-reachability check, or handshake watchdog.

## Route warnings and repair

An interface being up does not prove traffic reaches its destination. TunnelDeck
checks missing/conflicting routes and duplicate interface addresses and displays
warnings rather than treating them as healthy connections.

If another VPN removed routes during disconnect, deactivate that profile and its
on-demand rule, then use **Repair Routes…**. Repair explicitly adds missing routes
to the existing interface; it refuses competing conflicts and never deletes or
replaces another interface's route. Background status checks do not change routes.

## Updates

Quit using **Quit and Leave Connected**, replace the app in Applications, then
reopen it and approve **Install / Update…**. Updates do not intentionally restart
active tunnels. There is no automatic updater. Do not delete installed runtime
directories while tunnels are active; background route monitors may use them.

## Download checksums

Releases include `SHA256SUMS.txt` and corresponding source archives. To check a
downloaded DMG, run this in the folder containing it and the checksum file:

```sh
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```

Checksums detect corruption; they do not establish publisher identity. Current
releases are ad-hoc signed, not Developer ID signed or notarized.

## Limitations

- **Split tunnels only.** Default (`/0`) routes are rejected. This is not a
  full-tunnel VPN or kill switch; do not use broad routes to bypass that limit.
- **System DNS is preserved.** Imported `DNS` values are not applied. Private
  names need an existing resolver that can answer them; scoped DNS is not implemented.
- **Disjoint networks required.** Overlapping routes/interface networks between
  TunnelDeck tunnels are blocked. Other VPNs and local network routes may also conflict.
- **IPv4-preferred hostname endpoints.** Names are resolved again on connection
  and reconnect. IPv6-only names and explicit IPv6 endpoints remain supported.
  This is not application-health failover or automatic MTU discovery.
- **Not a System Settings VPN extension.** Tunnels use command-line WireGuard
  tools, not Apple's NetworkExtension framework, and do not appear in **System Settings → VPN**.
- No key generation, QR-code import, or custom configuration hooks.
- No production security audit. Handshakes and route health do not prove
  application reachability or traffic isolation under every network condition.

## Permissions and configuration storage

The app runs as your normal user. Administrator approval installs a persistent,
root-owned helper and LaunchDaemon; routine operations use authenticated XPC
without repeated password prompts. There is no sudoers rule or network listener.
Rebuilt ad-hoc apps require another approved service update to enroll their new signature.

Configurations are stored in Keychain. Active tunnels also require root-only
runtime configuration files; enabled on-demand rules require root-only persistent
copies. Configuration hooks and unsafe directives are rejected again by the helper.
Raw WireGuard output containing keys is not displayed or logged.

Release tools are hash-checked and copied into root-owned, content-addressed
directories. Source-only development builds use trusted Homebrew tools instead.
Trust in the app and its dependencies is required; hashes and ad-hoc signatures
are not a substitute for a security audit. See [SECURITY.md](../SECURITY.md), and
never include real keys or configuration exports in an issue.
