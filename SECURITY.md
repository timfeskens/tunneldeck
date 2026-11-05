# Security

TunnelDeck is an early, unaudited application. It manages network
interfaces as root after explicit macOS administrator authorization. Review the
README's privilege model and limitations before use.

Installing the root service explicitly authorizes a persistent root-owned helper
and LaunchDaemon. It accepts XPC requests only from enrolled signing identities,
enforced per message by macOS. The owner UID is derived from the connection.
The client also pins the server's signing requirement. Rebuilt ad-hoc apps need
one approved service update to enroll their new code hash.

Enabling on-demand also stores root-only persistent copies of enabled configs.
Disabling the last rule removes that rule/config but keeps the manual-control
root service installed. No production security audit has been performed.
Source-only development builds use trusted, user-writable Homebrew dependencies;
release builds install root-owned copies of their bundled runtime.
Wi-Fi rules fail closed when macOS withholds the SSID. Automatic activation
is not a kill switch and does not establish that traffic reached the peer.

Do not share real private keys, preshared keys, configuration exports, temporary
authorization request files, or Keychain contents in bug reports. Redact endpoint
and private-network information if your network requires it. Use synthetic keys
when reporting parser issues.

Report vulnerabilities privately through GitHub's **Security → Report a
vulnerability** for [timfeskens/tunneldeck](https://github.com/timfeskens/tunneldeck/security/advisories/new).
Do not post exploitable security issues or sensitive configurations in public issues.
If publishing a fork, provide a private security-reporting channel before distributing builds.

Release DMGs are Apple Silicon only and bundle Bash/WireGuard command-line tools.
The approved installer verifies their SHA-256 manifest and copies regular files
into root-owned, content-addressed Runtime directories. Existing runtime versions
are retained for active background route monitors. These hashes detect accidental
corruption; an ad-hoc signature/manifest is not publisher authentication.
These early downloads are not Developer ID signed or notarized.

Developer ID signing, notarization, review of the code-signature-validated XPC
boundary, and real-network integration testing are required before treating
this as a production VPN client. Unit tests alone do not establish safe routing,
DNS isolation, or recovery under all macOS network conditions.
