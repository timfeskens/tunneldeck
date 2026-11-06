# Development and release builds

Apple Silicon, macOS 14+, and Xcode / Swift 6 are required. The optional local test suite can be
run with `swift test` when present; it is not included in the repository.

## Build from source

A source-only build uses Homebrew tools:

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

### Stable local signing and Keychain access

The default remains ad-hoc signing. To use an existing Apple Development identity
for a local build, set `CODE_SIGN_IDENTITY` to its SHA-1 fingerprint when invoking
`scripts/build.sh`. List available identities with `security find-identity -v -p
codesigning`. Both app and helper are signed with the selected identity. Keep the
same bundle ID and signing identity on subsequent builds to retain Keychain trust.
Do not commit private keys/certificates or silently fall back when signing fails.
Apple Development signing is for local development; it is not Developer ID
distribution signing or notarization. Existing items may need a migration prompt.

The login-Keychain implementation uses macOS's legacy app-specific `SecAccess`
ACL API, which is deprecated but needed for the current non-sandboxed, ad-hoc
distribution model. A data-protection Keychain migration requires a separate
entitlement/provisioning/signing design. `LocalAuthentication` guards sensitive
UI operations; it is not represented as cryptographic user-presence protection
on the stored Keychain items.

- `Sources/TunnelDeck`: SwiftUI app, Keychain storage, and service client.
- `Sources/TunnelDeckCore`: configuration validation, ZIP import, routing models, and endpoint resolution.
- `Sources/TunnelDeckHelper`: privileged service, installer, and WireGuard runner.
- `scripts/`: app/runtime builds, DMG packaging, verification, and icon generation.

The unit-test suite is maintained locally and is not included in this repository.
CI builds a fresh checkout; release CI also verifies the packaged DMG. Live VPN
testing requires explicit test profiles and an independent recovery connection.

## Standalone release build

Use a working Go 1.26 toolchain in addition to the Swift/C build tools. CI pins
the exact Go version in `.github/workflows/release.yml`. Runtime sources and Bash
patch hashes are pinned in `scripts/build-runtime.sh` and `scripts/bash-patches.sha256`.

From a clean, committed checkout:

```sh
BUNDLE_RUNTIME=1 bash scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
git archive --format=tar.gz --prefix=TunnelDeck/ -o "dist/TunnelDeck-$VERSION-source.tar.gz" HEAD
bash scripts/package-dmg.sh
bash scripts/verify-dmg.sh "dist/TunnelDeck-$VERSION-arm64.dmg"
```

The build produces standalone Bash, `wg`, Darwin `wg-quick`, and `wireguard-go`.
The DMG contains the app, an Applications shortcut, installation notes, licenses,
and application/runtime source archives. Go dependencies are vendored in the
runtime source archive. Keep corresponding sources and notices when redistributing.

## Automated releases

Push a version tag matching `CFBundleShortVersionString`, such as `v0.6.1`.
The release workflow builds on an Apple Silicon runner, signs ad hoc, packages
the DMG, mounts and verifies it, and only then publishes the assets. It can also
be dispatched for an existing tag. Verification checks arm64 architecture,
signatures, runtime hashes, system-only dylib dependencies, and runtime smoke tests
without Homebrew on `PATH`; it does not install the service or change VPN routes.

Current releases are not Developer ID signed or notarized. Adding distribution
signing requires the appropriate identity, hardened-runtime review, and notarization;
do not describe ad-hoc signing as publisher authentication.

## Read-only service diagnostic

After approving installation of the matching signed app:

```sh
dist/TunnelDeck.app/Contents/MacOS/TunnelDeck --check-service
```

This checks service readiness and samples existing tunnels. It prints counts,
not keys, endpoints, or configurations, and never installs the helper or changes tunnels.

## Installed files

- App metadata: `~/Library/Application Support/TunnelDeck/profiles.json`.
- Imported configurations: the user's macOS Keychain.
- Helper: `/Library/Application Support/TunnelDeck/TunnelDeckHelper`.
- LaunchDaemon: `/Library/LaunchDaemons/codes.savvy.tunneldeck.service.plist`.
- Enrollments: root-only `Clients/<uid>.json` records under the application support directory.
- Bundled runtime copies: content-addressed `Runtimes/` directories there.
- On-demand configurations: root-only files under `OnDemand/<uid>/` there.
- Active runtime files: `/var/run/tunneldeck/<uid>/`, with configurations mode `0600`.

Use normal app controls for disconnect and recovery. Do not delete active runtime
files, WireGuard sockets, or old runtime directories while tunnels may use them.
The helper runs a root-owned copy of Darwin `wg-quick` with only its final launchd
blocking wait removed; it rejects unrecognized script layouts and does not modify
the original bundled/Homebrew script.

## App icon

Original artwork is included in `Resources/AppIcon.icns` and `Resources/AppIcon.png`
under the MIT license. Regenerate it with `swift scripts/generate-icon.swift`.
The build script regenerates it when its source changes.
