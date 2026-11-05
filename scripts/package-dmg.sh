#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/TunnelDeck.app}"
[[ "$(uname -m)" == arm64 ]] || { echo "Apple Silicon releases only." >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
[[ -f "$APP/Contents/Resources/Runtime/manifest.json" ]] || { echo "Run BUNDLE_RUNTIME=1 bash scripts/build.sh first." >&2; exit 1; }
codesign --verify --deep --strict "$APP"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tunneldeck-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/TunnelDeck.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/INSTALL.txt" "$STAGE/Read Me.txt"
cp "$ROOT/THIRD_PARTY.md" "$ROOT/LICENSE" "$STAGE/"
cp "$ROOT/dist/TunnelDeck-runtime-sources.tar.gz" "$STAGE/"
cp "$ROOT/dist/TunnelDeck-$VERSION-source.tar.gz" "$STAGE/"
DMG="$ROOT/dist/TunnelDeck-$VERSION-arm64.dmg"
hdiutil create -volname "TunnelDeck $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
(cd "$ROOT/dist" && shasum -a 256 "TunnelDeck-$VERSION-arm64.dmg" "TunnelDeck-$VERSION-source.tar.gz" TunnelDeck-runtime-sources.tar.gz > SHA256SUMS.txt)
echo "Created $DMG"
