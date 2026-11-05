#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "${BUNDLE_RUNTIME:-0}" == 1 ]]; then
    bash scripts/build-runtime.sh
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/TunnelDeck.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ ! -f "$ROOT/Resources/AppIcon.icns" || "$ROOT/scripts/generate-icon.swift" -nt "$ROOT/Resources/AppIcon.icns" ]]; then
    swift "$ROOT/scripts/generate-icon.swift"
fi
cp "$BIN/TunnelDeck" "$APP/Contents/MacOS/TunnelDeck"
cp "$BIN/TunnelDeckHelper" "$APP/Contents/MacOS/TunnelDeckHelper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [[ "${BUNDLE_RUNTIME:-0}" == 1 ]]; then
    mkdir -p "$APP/Contents/Resources/Runtime"
    ditto "$ROOT/dist/runtime" "$APP/Contents/Resources/Runtime"
    cp "$ROOT/THIRD_PARTY.md" "$APP/Contents/Resources/THIRD_PARTY.md"
fi
# Ad-hoc signing is suitable for local builds, not public distribution.
codesign --force --sign - "$APP/Contents/MacOS/TunnelDeckHelper"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\nLaunch with: open "%s"\n' "$APP" "$APP"
