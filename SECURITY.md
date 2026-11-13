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
authorization request files, Keychain contents, or screenshots showing revealed
keys in bug reports. Redact endpoint and private-network information if your
network requires it. Use synthetic keys when reporting parser issues.

ZIP exports are unencrypted
and include the selected configurations' secrets. They are created only after
an explicit user selection and save confirmation, with owner-only file permissions.
Do not store them in public or shared folders.

Interactive editing, revealing keys and export require LocalAuthentication
(Touch ID or Mac login password). This is an app-level disclosure gate, not a
biometric Keychain ACL. Saved configurations explicitly trust the signed app,
never every application. Normal Keychain operations suppress interactive system
permission dialogs and never change ACLs. Explicit per-tunnel **Repair Keychain
Access…** permits macOS to authorize an in-place ACL update without disclosing or
replacing the secret. Cancellation does not trigger retries. Writes and removals
verify decrypt access noninteractively before mutating existing items. Ad-hoc
rebuilds can require repair again. Stable signing is needed to preserve trust.

Connected edits reconnect only the selected tunnel under the shared operation
lock, including on-demand configuration changes. Validation and endpoint lookup
precede disconnect. Failed updates attempt restoration; recovery failure is
reported explicitly. Client timeouts do not prove completion or cancel work;
saved new settings are retained when the service result is unknown.

Directly connected Wi-Fi/Ethernet subnets fully covering configured destinations
are preserved as explicit local-LAN bypasses. That traffic is not VPN-encrypted;
the app identifies the bypass. Saved AllowedIPs and WireGuard peer policy remain
unchanged. Matching subnets do not authenticate a trusted home network. Gateway
routes, partial LAN overlap, duplicate interface addresses and competing VPN
routes are not exempted. No existing LAN route is deleted or replaced.

Background route recovery uses the shared operation lock and the same conflict
checks as manual repair. It adds missing routes only; it never disconnects a
manual tunnel or deletes another interface's routes. Repairs and on-demand
activation use at most three attempts with backoff per network/connection epoch;
explicit retry or service restart resets the in-memory budget. This is not a
handshake watchdog or kill switch. Route health is not proof of peer reachability.

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
