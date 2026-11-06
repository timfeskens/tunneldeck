#!/bin/bash
# Build redistributable arm64 tools without Homebrew-linked dylibs. Include
# corresponding sources (including Go's vendored dependencies) in each release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -m)" == arm64 ]] || { echo "Release runtime supports Apple Silicon only." >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tunneldeck-runtime.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
OUT="$ROOT/dist/runtime"
mkdir -p "$OUT/bin" "$OUT/Licenses" "$WORK/sources"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-O2 -mmacosx-version-min=14.0"
export LDFLAGS="-mmacosx-version-min=14.0"
JOBS="$(sysctl -n hw.ncpu)"

curl --fail --location --retry 3 https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz -o "$WORK/bash.tar.gz"
echo "0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba  $WORK/bash.tar.gz" | shasum -a 256 -c -
tar -xzf "$WORK/bash.tar.gz" -C "$WORK/sources"
mkdir -p "$WORK/patches"
while read -r checksum name; do
    curl --fail --location --retry 3 "https://ftp.gnu.org/gnu/bash/bash-5.3-patches/$name" -o "$WORK/patches/$name"
    echo "$checksum  $WORK/patches/$name" | shasum -a 256 -c -
    (cd "$WORK/sources/bash-5.3" && patch -p0 < "$WORK/patches/$name")
done < "$ROOT/scripts/bash-patches.sha256"
cp "$WORK/sources/bash-5.3/COPYING" "$OUT/Licenses/bash-GPL-3.0.txt"
# No interactive readline/gettext or user-loadable modules in a VPN script runner.
cp -R "$WORK/sources/bash-5.3" "$WORK/bash-build"
# Upstream patches update configure.ac as well as the shipped configure script.
# Build that shipped script; do not require autoconf just because timestamps from
# extraction/patching make its inputs appear newer.
touch "$WORK/bash-build/configure"
# Use Bash's shipped parser rather than regenerating it with macOS's old yacc.
# No pinned upstream patch changes parse.y. Archive/copy timestamps can otherwise
# make make rebuild y.tab.c, which requires a newer Bison than Apple's provides.
touch "$WORK/bash-build/y.tab.c" "$WORK/bash-build/y.tab.h"
# Recent SDKs expose strchrnul even when targeting older macOS. Use Bash's
# fallback instead of importing the symbol introduced in macOS 15.4.
(cd "$WORK/bash-build" && bash_cv_func_strchrnul_works=no ac_cv_lib_dl_dlopen=no ac_cv_func_dlopen=no ac_cv_func_dlclose=no ac_cv_func_dlsym=no ./configure --prefix=/usr --without-bash-malloc --disable-readline --disable-nls --disable-progcomp > "$WORK/bash-configure.log" && make -j "$JOBS" > "$WORK/bash-build.log") || { cat "$WORK/bash-configure.log" "$WORK/bash-build.log"; exit 1; }
cp "$WORK/bash-build/bash" "$OUT/bin/bash"

git clone --quiet https://git.zx2c4.com/wireguard-tools "$WORK/tools"
git -C "$WORK/tools" checkout --quiet 49ce333da02056ae7b22ee2aeb6afe8aaed79b19
mkdir "$WORK/sources/wireguard-tools"
git -C "$WORK/tools" archive HEAD | tar -xf - -C "$WORK/sources/wireguard-tools"
make -C "$WORK/tools/src" -j "$JOBS" wg
cp "$WORK/tools/src/wg" "$OUT/bin/wg"
cp "$WORK/tools/src/wg-quick/darwin.bash" "$OUT/bin/wg-quick"
cp "$WORK/tools/COPYING" "$OUT/Licenses/wireguard-tools-GPL-2.0.txt"

git clone --quiet https://git.zx2c4.com/wireguard-go "$WORK/go"
git -C "$WORK/go" checkout --quiet f333402bd9cbe0f3eeb02507bd14e23d7d639280
mkdir "$WORK/sources/wireguard-go"
git -C "$WORK/go" archive HEAD | tar -xf - -C "$WORK/sources/wireguard-go"
(cd "$WORK/sources/wireguard-go" && go mod vendor && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -mod=vendor -trimpath -o "$OUT/bin/wireguard-go" .)
cp "$WORK/sources/wireguard-go/LICENSE" "$OUT/Licenses/wireguard-go-MIT.txt"
cp "$(go env GOROOT)/LICENSE" "$OUT/Licenses/Go-BSD-3-Clause.txt"
cp "$(go env GOROOT)/PATENTS" "$OUT/Licenses/Go-PATENTS.txt"
cp "$ROOT/scripts/build-runtime.sh" "$ROOT/scripts/bash-patches.sha256" "$WORK/sources/"
cat > "$WORK/sources/BUILD-INFO.txt" <<EOF
Bash 5.3 with upstream patches 001–020; wireguard-tools 49ce333da02056ae7b22ee2aeb6afe8aaed79b19;
wireguard-go f333402bd9cbe0f3eeb02507bd14e23d7d639280, with vendored dependencies.
Toolchain: $(go version); $(clang --version | head -1)
Build instructions: build-runtime.sh (included); target macOS 14+, arm64.
These are separate command-line programs, not linked into TunnelDeck.
EOF
chmod 755 "$OUT/bin/"*
for file in bash wg wireguard-go; do codesign --force --sign - "$OUT/bin/$file"; done
python3 - "$OUT" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
undefined = subprocess.check_output(['nm', '-u', str(root / 'bin/bash')], text=True)
if '_strchrnul' in undefined:
    raise SystemExit('Bash imports strchrnul, which requires macOS 15.4')
if '_dlopen' in undefined:
    raise SystemExit('Bash loadable modules were not disabled')
for name in ['bash', 'wg', 'wireguard-go']:
    path = root / 'bin' / name
    links = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
    if any(not line.strip().startswith(('/usr/lib/', '/System/Library/')) for line in links):
        raise SystemExit(f'{name} has a non-system dynamic library dependency')
manifest = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((root / 'bin').iterdir())}
(root / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
PY
tar -czf "$ROOT/dist/TunnelDeck-runtime-sources.tar.gz" -C "$WORK" sources
echo "Built standalone runtime in $OUT"
