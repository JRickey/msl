#!/bin/sh
# Cross-build a static libxkbcommon.a (aarch64-unknown-linux-musl) for msl-way.
# Output: guest/target/xkb-musl/libxkbcommon.a — the -L native path the
# xkbcommon crate's `#[link(name = "xkbcommon")]` resolves against. Static core
# only (no x11, wayland, registry, tools, docs). Idempotent: skips when the .a
# already exists. Toolchain: meson + ninja + zig cc (cross) + bison >= 3.8.
set -eu

XKB_VERSION="1.7.0"
XKB_ARCHIVE_NAME="libxkbcommon-xkbcommon-${XKB_VERSION}"
XKB_URL="https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-${XKB_VERSION}.tar.gz"

# Resolve repo-root-relative paths from this script's location (tools/).
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_DIR="$REPO_ROOT/guest/target/xkb-musl"
OUT_LIB="$OUT_DIR/libxkbcommon.a"
WORK_DIR="$REPO_ROOT/guest/target/xkb-build"
SRC_DIR="$WORK_DIR/$XKB_ARCHIVE_NAME"
BUILD_DIR="$SRC_DIR/build-musl"

if [ -f "$OUT_LIB" ]; then
    echo "mk-libxkbcommon: $OUT_LIB exists; skip (delete it to force a rebuild)"
    exit 0
fi

fail() {
    echo "mk-libxkbcommon: $1" >&2
    exit 1
}

# --- toolchain preconditions (fail early, with install hints) ------------------
command -v zig >/dev/null 2>&1 || fail "zig not found — 'brew install zig' (>= 0.13)"
command -v ninja >/dev/null 2>&1 || fail "ninja not found — 'brew install ninja'"

MESON=""
if command -v meson >/dev/null 2>&1; then
    MESON="meson"
elif python3 -c 'import mesonbuild' >/dev/null 2>&1; then
    MESON="python3 -m mesonbuild.mesonmain"
else
    fail "meson not found — 'brew install meson' or 'pip3 install --user meson'"
fi

# Homebrew bison (>= 3.8) is required; macOS /usr/bin/bison is 2.3 and too old.
BISON_BIN=""
if [ -x /opt/homebrew/opt/bison/bin/bison ]; then
    BISON_BIN=/opt/homebrew/opt/bison/bin/bison
elif [ -x /usr/local/opt/bison/bin/bison ]; then
    BISON_BIN=/usr/local/opt/bison/bin/bison
elif command -v bison >/dev/null 2>&1; then
    BISON_BIN=$(command -v bison)
else
    fail "bison not found — 'brew install bison' (need >= 3.8; system 2.3 is too old)"
fi
BISON_MAJOR=$("$BISON_BIN" --version | sed -n '1s/.* \([0-9]*\)\.\([0-9]*\).*/\1/p')
BISON_MINOR=$("$BISON_BIN" --version | sed -n '1s/.* \([0-9]*\)\.\([0-9]*\).*/\2/p')
[ -n "$BISON_MAJOR" ] || fail "could not parse bison version from '$BISON_BIN'"
if [ "$BISON_MAJOR" -lt 3 ] || { [ "$BISON_MAJOR" -eq 3 ] && [ "$BISON_MINOR" -lt 8 ]; }; then
    fail "bison $BISON_MAJOR.$BISON_MINOR too old at '$BISON_BIN' — need >= 3.8 ('brew install bison')"
fi
# meson finds bison and its skeletons through PATH.
PATH="$(dirname "$BISON_BIN"):$PATH"
export PATH

mkdir -p "$WORK_DIR" "$OUT_DIR"

# --- fetch + extract source (reuse an existing extraction) ---------------------
if [ ! -d "$SRC_DIR" ]; then
    TARBALL="$WORK_DIR/${XKB_ARCHIVE_NAME}.tar.gz"
    if [ ! -f "$TARBALL" ]; then
        command -v curl >/dev/null 2>&1 || fail "curl not found — needed to fetch libxkbcommon"
        echo "mk-libxkbcommon: fetching $XKB_URL"
        curl -fsSL "$XKB_URL" -o "$TARBALL" || fail "download failed: $XKB_URL"
    fi
    tar -xzf "$TARBALL" -C "$WORK_DIR" || fail "extract failed: $TARBALL"
fi
[ -f "$SRC_DIR/meson.build" ] || fail "source tree incomplete at $SRC_DIR (no meson.build)"

# --- zig cross wrappers + meson cross file -------------------------------------
CC_WRAP="$WORK_DIR/zig-cc.sh"
AR_WRAP="$WORK_DIR/zig-ar.sh"
CROSS_FILE="$WORK_DIR/cross-aarch64-musl.ini"

cat >"$CC_WRAP" <<'EOF'
#!/bin/sh
exec zig cc -target aarch64-linux-musl "$@"
EOF
cat >"$AR_WRAP" <<'EOF'
#!/bin/sh
exec zig ar "$@"
EOF
chmod +x "$CC_WRAP" "$AR_WRAP"

cat >"$CROSS_FILE" <<EOF
[binaries]
c = '$CC_WRAP'
ar = '$AR_WRAP'
strip = 'true'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

# --- configure + build ---------------------------------------------------------
rm -rf "$BUILD_DIR"
# shellcheck disable=SC2086
$MESON setup "$BUILD_DIR" "$SRC_DIR" \
    --cross-file "$CROSS_FILE" \
    --buildtype release \
    -Ddefault_library=static \
    -Denable-x11=false \
    -Denable-wayland=false \
    -Denable-xkbregistry=false \
    -Denable-tools=false \
    -Denable-docs=false \
    -Denable-bash-completion=false \
    || fail "meson setup failed"

ninja -C "$BUILD_DIR" libxkbcommon.a || fail "ninja build of libxkbcommon.a failed"

[ -f "$BUILD_DIR/libxkbcommon.a" ] || fail "build produced no libxkbcommon.a"
cp "$BUILD_DIR/libxkbcommon.a" "$OUT_LIB"
echo "mk-libxkbcommon: wrote $OUT_LIB"
