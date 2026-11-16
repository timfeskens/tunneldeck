## New in v0.6.5

- Local build 16: show Repair Keychain Access only after a silent selected-tunnel
  check confirms an authorization failure; hide it after verified repair. Recheck
  when selecting a tunnel, returning to the app, and completing actions. Missing
  entries and unrelated Keychain errors do not offer permission repair.
- Replace the failed direct-ACL/password-authorized repair with
  one explicit Keychain read. Use macOS's Always Allow authorization flow, then
  verify access silently. Remove the app-owned password field and private API;
  preserve saved entries and keep routine reads noninteractive.

- Automatically repair missing routes after roaming, with a maximum of three
  attempts and 5/15/30-second backoff. Recovery runs in the root service even when
  the app is closed, preserves other VPNs, and reports exhausted retries.
- Clicking an active tunnel with unhealthy/unknown routes now retries repair
  instead of disconnecting it. Disconnect remains a separate explicit action.
- On-demand activation failures now have a bounded retry budget too.
- Preserve fully covered directly connected Wi-Fi/Ethernet destinations as local
  LAN bypasses. The app identifies that traffic is not using the VPN; saved
  AllowedIPs remain unchanged for connection away from the LAN.
- Stop cascading Keychain permission dialogs: routine access is noninteractive,
  permission repair is explicit per tunnel, and connecting no longer reads other
  profiles' secrets. Touch ID still guards editing, revealing and export.
- The installed local build can use the selected stable Apple Development
  signing identity; public releases remain ad-hoc signed and not notarized.

## Previous release: v0.6.4

This release includes the connected-editing and authentication changes planned
for v0.6.3, whose release build failed before publication. The bundled Bash build
now uses its shipped parser instead of trying to regenerate it with macOS's older
yacc. No v0.6.3 download was published.

- **Edit connected tunnels** without disconnecting first. **Save & Reconnect**
  briefly reconnects only the edited tunnel; there is no save-for-later mode.
  Saving a disconnected tunnel does not activate it.
- Configuration, route conflicts, and endpoint resolution are checked before
  disconnecting. On-demand configuration updates use the same operation lock.
  Failed updates attempt to restore the previous configuration and connection;
  incomplete recovery is reported explicitly. If the service response is lost,
  saved new settings are retained because the operation may still be running.
- **Touch ID or your Mac login password** is now required for editing existing
  configurations, revealing imported keys, and exporting tunnels. Routine status
  checks and background on-demand operations do not request biometric approval.
- Keychain entries explicitly trust the app, not all applications. Existing
  entries migrate in place after a successful read, preserving their contents.
  macOS may request Keychain permission during migration or after future ad-hoc
  updates. Touch ID is an app-level disclosure gate, not a biometric Keychain ACL,
  and does not replace those system permission checks.
- Local builds can opt into an existing stable signing identity through
  `CODE_SIGN_IDENTITY`. Public release signing remains ad hoc, not notarized.

Automated validation covers replacement sequencing, the local test suite, and
disposable Keychain storage/migration. Live reconnect/recovery and interactive
Touch ID approval have not been end-to-end validated for this release.

## Install

**Apple Silicon (M-series), macOS 14 or newer. Intel is not supported.**

Download the arm64 DMG, open it, drag **TunnelDeck.app → Applications**, then
launch the installed app. Approve **Install / Update…** once for its root service.
The WireGuard runtime is bundled: **Homebrew is not required**.

**Early release: ad-hoc signed, not notarized.** macOS may block the first
launch; use **System Settings → Privacy & Security → Open Anyway** only after
verifying that you trust the download. Do not disable Gatekeeper globally.

Do not activate the same WireGuard profile in both apps. Disable the old copy's
on-demand setting before migrating. Split tunnels only; system DNS is preserved.

## Included

- Native tunnel list, menu-bar controls, selected ZIP export/import, Keychain storage.
- Simultaneous disjoint tunnels and per-tunnel on-demand activation.
- Root service for password-free routine operations, automatic route/stat refresh,
  duplicate-address warnings, and deliberate route repair.
- IPv4-preferred hostname endpoints to avoid the reproduced dual-stack TLS stall.
- Apple Silicon DMG with standalone Bash, WireGuard tools, and wireguard-go.

Checksum list and corresponding application/runtime sources accompany this
release. Keep the source archives and third-party notices when redistributing.
See the included Read Me and repository README for limitations and updates.
