## New in v0.6.3

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
