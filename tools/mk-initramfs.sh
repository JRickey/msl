#!/bin/sh
# Build build/initramfs.cpio (newc) for the msl M0 guest: the agent as /init
# plus a pinned static aarch64 busybox and a fixed set of applet symlinks.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

BUILD_DIR="$REPO_ROOT/build"
CACHE_DIR="$BUILD_DIR/cache"
OUT="$BUILD_DIR/initramfs.cpio"
AGENT="$REPO_ROOT/guest/target/aarch64-unknown-linux-musl/release/msl-agent"
SHIM="$REPO_ROOT/guest/target/aarch64-unknown-linux-musl/release/mac"
FSD="$REPO_ROOT/guest/target/aarch64-unknown-linux-musl/release/msl-fsd"
WAY="$REPO_ROOT/guest/target/aarch64-unknown-linux-musl/release/msl-way"

# Pinned busybox: Alpine v3.21 aarch64 static build. The multiarch busybox.net
# binaries ship only 32-bit armv8l for ARM, which will not run on this kernel.
BB_VERSION="1.37.0-r14"
APK_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/busybox-static-$BB_VERSION.apk"
APK_SHA256="6fd7ea97062beb51fa785ba858f823e1dfe4daf6bfa91ff4d5359b1061988c69"
BB_SHA256="e383c8bc25a1137b8ee88718cc6df1f1e84c54521d6045fc837385995dcdf031"

APK="$CACHE_DIR/busybox-static-$BB_VERSION.apk"
BB="$CACHE_DIR/busybox-$BB_VERSION.aarch64"

APPLETS="sh echo cat uname"

verify_sha256() {
	f="$1"
	want="$2"
	[ -f "$f" ] || return 1
	have=$(shasum -a 256 "$f" | awk '{print $1}')
	[ "$have" = "$want" ]
}

if [ ! -f "$AGENT" ]; then
	echo "mk-initramfs: missing guest agent: $AGENT" >&2
	echo "  build it first: (cd guest && cargo zigbuild --target aarch64-unknown-linux-musl --release)" >&2
	exit 1
fi

if [ ! -f "$FSD" ]; then
	echo "mk-initramfs: missing fs worker: $FSD" >&2
	echo "  build it first: (cd guest && cargo zigbuild --target aarch64-unknown-linux-musl --release)" >&2
	exit 1
fi

if [ ! -f "$SHIM" ]; then
	echo "mk-initramfs: missing interop shim: $SHIM" >&2
	echo "  build it first: (cd guest && cargo zigbuild --workspace --target aarch64-unknown-linux-musl --release)" >&2
	exit 1
fi

if [ "${REQUIRE_MSL_WAY:-0}" = "1" ] && [ ! -f "$WAY" ]; then
	echo "mk-initramfs: missing wayland compositor: $WAY" >&2
	echo "  build it first: make msl-way" >&2
	exit 1
fi

mkdir -p "$CACHE_DIR"

if ! verify_sha256 "$APK" "$APK_SHA256"; then
	echo "mk-initramfs: fetching busybox apk $BB_VERSION"
	curl -fSsL -o "$APK.part" "$APK_URL"
	mv "$APK.part" "$APK"
	if ! verify_sha256 "$APK" "$APK_SHA256"; then
		echo "ERROR: busybox apk sha256 mismatch" >&2
		echo "  expected: $APK_SHA256" >&2
		echo "  actual:   $(shasum -a 256 "$APK" | awk '{print $1}')" >&2
		rm -f "$APK"
		exit 1
	fi
fi

if ! verify_sha256 "$BB" "$BB_SHA256"; then
	# Alpine apks are concatenated gzip streams; libarchive tar reads them.
	tmp=$(mktemp -d "$CACHE_DIR/apk.XXXXXX")
	trap 'rm -rf "$tmp"' EXIT INT TERM
	tar -xzf "$APK" -C "$tmp" bin/busybox.static
	cp "$tmp/bin/busybox.static" "$BB.part"
	mv "$BB.part" "$BB"
	rm -rf "$tmp"
	trap - EXIT INT TERM
	if ! verify_sha256 "$BB" "$BB_SHA256"; then
		echo "ERROR: extracted busybox sha256 mismatch" >&2
		echo "  expected: $BB_SHA256" >&2
		echo "  actual:   $(shasum -a 256 "$BB" | awk '{print $1}')" >&2
		rm -f "$BB"
		exit 1
	fi
fi

case "$(file -b "$BB")" in
	*aarch64*statically*) : ;;
	*) echo "ERROR: cached busybox is not a static aarch64 binary: $(file -b "$BB")" >&2; exit 1 ;;
esac

stage=$(mktemp -d "$BUILD_DIR/initramfs.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM

mkdir -p "$stage/proc" "$stage/sys" "$stage/dev" "$stage/bin" "$stage/tools"
mkdir -m 0777 -p "$stage/tmp"

install -m 0755 "$AGENT" "$stage/init"
install -m 0755 "$BB" "$stage/bin/busybox"
install -m 0755 "$SHIM" "$stage/tools/mac"
install -m 0755 "$FSD" "$stage/tools/msl-fsd"
if [ -f "$WAY" ]; then
	install -m 0755 "$WAY" "$stage/tools/msl-way"
fi
ln -s mac "$stage/tools/mac-binfmt"

n=0
for applet in $APPLETS; do
	[ "$n" -lt 16 ] || { echo "ERROR: applet loop bound exceeded" >&2; exit 1; }
	ln -sf busybox "$stage/bin/$applet"
	n=$((n + 1))
done

cpio_err=$(mktemp "$BUILD_DIR/cpio-err.XXXXXX")
( cd "$stage" && find . | LC_ALL=C sort | cpio -o --format newc -R 0:0 ) > "$OUT.part" 2>"$cpio_err"
mv "$OUT.part" "$OUT"
grep -vE '^[0-9]+ blocks?$' "$cpio_err" >&2 || true
rm -f "$cpio_err"

rm -rf "$stage"
trap - EXIT INT TERM

echo "mk-initramfs: wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
