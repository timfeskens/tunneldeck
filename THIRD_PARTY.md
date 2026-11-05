# Bundled runtime notices

Release DMGs include separate command-line programs used by TunnelDeck:

| Program | Version | License | Upstream |
| --- | --- | --- | --- |
| GNU Bash | 5.3, patches 001–020 | GPL-3.0-or-later | https://www.gnu.org/software/bash/ |
| WireGuard tools (`wg`, Darwin `wg-quick`) | 1.0.20260223 | GPL-2.0-only | https://git.zx2c4.com/wireguard-tools/ |
| wireguard-go | 0.0.20250522 | MIT | https://git.zx2c4.com/wireguard-go/ |

These programs run as separate processes; they are not linked into TunnelDeck.
License texts are in `TunnelDeck.app/Contents/Resources/Runtime/Licenses`.
The Go runtime's BSD license and patent grant are included there as well.
Corresponding source for the exact bundled versions, Go's vendored dependencies
(with their license files), and the build instructions accompany each release as
`TunnelDeck-runtime-sources.tar.gz`. The DMG also contains this source archive.
If you redistribute the DMG, retain the corresponding sources and license notices.

The helper makes a temporary copy of Darwin `wg-quick` at runtime with only its
launchd blocking-wait line replaced. This keeps requests finite while the
TunnelDeck root service supervises them; the original source is unmodified in
the bundled runtime. That transformation is documented in
`Sources/TunnelDeckHelper/main.swift` and included in TunnelDeck's source archive.

TunnelDeck's own source is MIT licensed; see `LICENSE`. This does not replace or
relicense the separately bundled programs or their dependencies.
