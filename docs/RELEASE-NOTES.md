## Install

**Apple Silicon (M-series), macOS 14 or newer. Intel is not supported.**

Download the arm64 DMG, open it, drag **TunnelDeck.app → Applications**, then
launch the installed app. Approve **Install / Update…** once for its root service.
The WireGuard runtime is bundled: **Homebrew is not required**.

**Early private release: ad-hoc signed, not notarized.** macOS may block the first
launch; use **System Settings → Privacy & Security → Open Anyway** only after
verifying that you trust the download. Do not disable Gatekeeper globally.

Do not activate the same WireGuard profile in both apps. Disable the old copy's
on-demand setting before migrating. Split tunnels only; system DNS is preserved.

## Included

- Release-build fix for patched Bash on clean GitHub runners; loadable modules disabled.

- Native tunnel list, menu-bar controls, ZIP import, Keychain storage.
- Simultaneous disjoint tunnels and per-tunnel on-demand activation.
- Root service for password-free routine operations, automatic route/stat refresh,
  duplicate-address warnings, and deliberate route repair.
- IPv4-preferred hostname endpoints to avoid the reproduced dual-stack TLS stall.
- Apple Silicon DMG with standalone Bash, WireGuard tools, and wireguard-go.

Checksum list and corresponding application/runtime sources accompany this
release. Keep the source archives and third-party notices when redistributing.
See the included Read Me and repository README for limitations and updates.
