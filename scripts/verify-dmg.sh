#!/bin/bash
set -euo pipefail
DMG="$1"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/tunneldeck-mounted.XXXXXX")"
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT"
APP="$MOUNT/TunnelDeck.app"
codesign --verify --deep --strict "$APP"
[[ -L "$MOUNT/Applications" ]]
[[ -f "$MOUNT/TunnelDeck-runtime-sources.tar.gz" ]]
RUNTIME="$APP/Contents/Resources/Runtime"
env PATH=/usr/bin:/bin:/usr/sbin:/sbin "$RUNTIME/bin/bash" -c 'declare -A values; values[test]=ok; [[ ${values[test]} == ok ]]'
env PATH=/usr/bin:/bin:/usr/sbin:/sbin "$RUNTIME/bin/bash" -n "$RUNTIME/bin/wg-quick"
env PATH=/usr/bin:/bin:/usr/sbin:/sbin "$RUNTIME/bin/bash" "$RUNTIME/bin/wg-quick" --help
env PATH=/usr/bin:/bin:/usr/sbin:/sbin "$RUNTIME/bin/wg" --version
env PATH=/usr/bin:/bin:/usr/sbin:/sbin "$RUNTIME/bin/wireguard-go" --version
python3 - "$APP" <<'PY'
import hashlib, json, pathlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
runtime = app / 'Contents/Resources/Runtime'
manifest = json.loads((runtime / 'manifest.json').read_text())
assert (app / 'Contents/Info.plist').is_file()
assert list(app.parent.glob('TunnelDeck-*-source.tar.gz'))
assert subprocess.check_output(['readlink', str(app.parent / 'Applications')], text=True).strip() == '/Applications'
assert '_strchrnul' not in subprocess.check_output(['nm', '-u', str(runtime / 'bin/bash')], text=True)
assert set(manifest) == {'bash', 'wg', 'wg-quick', 'wireguard-go'}
for name, checksum in manifest.items():
    path = runtime / 'bin' / name
    assert hashlib.sha256(path.read_bytes()).hexdigest() == checksum
for path in [app / 'Contents/MacOS/TunnelDeck', app / 'Contents/MacOS/TunnelDeckHelper', *[runtime / 'bin' / n for n in ['bash', 'wg', 'wireguard-go']]]:
    assert subprocess.check_output(['lipo', '-archs', str(path)], text=True).strip() == 'arm64'
    links = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
    assert all(line.strip().startswith(('/usr/lib/', '/System/Library/')) for line in links), links
print('Verified arm64, signatures, hashes, and absence of Homebrew dylib dependencies.')
PY
