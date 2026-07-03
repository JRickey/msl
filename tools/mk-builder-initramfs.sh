#!/bin/sh
# Build build/builder-initramfs.cpio (newc): an Alpine minirootfs with the
# msl-agent as /init, plus e2fsprogs (mkfs.ext4), GNU tar, and xz staged in for
# the M1 rootfs build VM. Pins mirror tools/mk-initramfs.sh discipline.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

BUILD_DIR="$REPO_ROOT/build"
CACHE_DIR="$BUILD_DIR/cache"
OUT="$BUILD_DIR/builder-initramfs.cpio"
AGENT="$REPO_ROOT/guest/target/aarch64-unknown-linux-musl/release/msl-agent"

ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v3.21"
MINIROOTFS="alpine-minirootfs-3.21.7-aarch64.tar.gz"
MINIROOTFS_URL="$ALPINE_MIRROR/releases/aarch64/$MINIROOTFS"
MINIROOTFS_SHA256="d1d1a3fae5f4d6146e9742790a47fcb116199622cfb8439f218a4d5fbe5000da"

# Alpine v3.21 main aarch64 apks. Dependency closure resolved manually against
# the APKINDEX down to musl libc (already in the minirootfs): e2fsprogs pulls
# libblkid (→libeconf), libcom_err, e2fsprogs-libs, libuuid; tar pulls acl-libs;
# xz pulls xz-libs. Each line: "name-version sha256(apk file)".
APKS="
e2fsprogs-1.47.1-r1 c28dddb51a40a91820a9f0dcd32f19abf23c8256543d7afc4f87363b28885a66
e2fsprogs-libs-1.47.1-r1 c817ddefbfa19245cce0c62820a1eb50c771f4999232d0a1c9e57521a58508d3
libblkid-2.40.4-r1 61339f8737b05062f662cfc30c65cb34f10ccc53573846653551c66156c4aa0b
libcom_err-1.47.1-r1 0798fedbc002cada8e74a7cb4cdae885e5f0c1b5fd59b15af5b2903b95d30153
libuuid-2.40.4-r1 d392ac96027cbe5ca9bc270d2aa4e99747b0eae3cf65a0087f2c6f13a7382702
libeconf-0.6.3-r0 db25f8abaf1ec61f5dcc0ff9b55271a3f6e43037e430b0c126ac000483e17dad
tar-1.35-r2 94fd82a516feedeb93d384eee9e244f0cf02393a0a31d7719db4780cfa180032
acl-libs-2.3.2-r1 b0d03f1eed5d5c083a5a11b780a4f89ccdfc5619ebbd822c8c1f09df179b7802
xz-5.8.3-r0 1a1dc6c6965f8ae7365e36de5afc3603a65c6b467348c6a0c3a730fd53eae93c
xz-libs-5.8.3-r0 992ee804cb54b0f7067f50ccfab641b253cab8659792be24ca6dd31795d87466
"

verify_sha256() {
	f="$1"
	want="$2"
	[ -f "$f" ] || return 1
	have=$(shasum -a 256 "$f" | awk '{print $1}')
	[ "$have" = "$want" ]
}

fetch_pinned() {
	url="$1"
	dest="$2"
	want="$3"
	if verify_sha256 "$dest" "$want"; then
		return 0
	fi
	echo "mk-builder-initramfs: fetching $(basename "$dest")"
	curl -fSsL -o "$dest.part" "$url"
	mv "$dest.part" "$dest"
	if ! verify_sha256 "$dest" "$want"; then
		echo "ERROR: sha256 mismatch for $(basename "$dest")" >&2
		echo "  expected: $want" >&2
		echo "  actual:   $(shasum -a 256 "$dest" | awk '{print $1}')" >&2
		rm -f "$dest"
		exit 1
	fi
}

if [ ! -f "$AGENT" ]; then
	echo "mk-builder-initramfs: missing guest agent: $AGENT" >&2
	echo "  build it first: (cd guest && cargo zigbuild --target aarch64-unknown-linux-musl --release)" >&2
	exit 1
fi

mkdir -p "$CACHE_DIR"

fetch_pinned "$MINIROOTFS_URL" "$CACHE_DIR/$MINIROOTFS" "$MINIROOTFS_SHA256"

n=0
echo "$APKS" | while read -r name sha; do
	[ -n "$name" ] || continue
	[ "$n" -lt 64 ] || { echo "ERROR: apk loop bound exceeded" >&2; exit 1; }
	fetch_pinned "$ALPINE_MIRROR/main/aarch64/$name.apk" "$CACHE_DIR/$name.apk" "$sha"
	n=$((n + 1))
done

stage=$(mktemp -d "$BUILD_DIR/builder-initramfs.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM

tar -xzf "$CACHE_DIR/$MINIROOTFS" -C "$stage"

n=0
echo "$APKS" | while read -r name sha; do
	[ -n "$name" ] || continue
	[ "$n" -lt 64 ] || { echo "ERROR: apk extract loop bound exceeded" >&2; exit 1; }
	tar -xzf "$CACHE_DIR/$name.apk" -C "$stage"
	n=$((n + 1))
done

rm -f "$stage/.PKGINFO" "$stage/.SIGN."* "$stage/.pre-install" \
	"$stage/.post-install" "$stage/.pre-upgrade" "$stage/.post-upgrade" \
	"$stage/.trigger"

if [ ! -x "$stage/sbin/mkfs.ext4" ] && [ ! -L "$stage/sbin/mkfs.ext4" ]; then
	echo "ERROR: mkfs.ext4 missing from staged builder rootfs" >&2
	exit 1
fi
if [ ! -x "$stage/usr/bin/tar" ] && [ ! -L "$stage/usr/bin/tar" ]; then
	echo "ERROR: GNU tar missing from staged builder rootfs" >&2
	exit 1
fi
if [ ! -x "$stage/usr/bin/xz" ]; then
	echo "ERROR: xz missing from staged builder rootfs" >&2
	exit 1
fi

install -m 0755 "$AGENT" "$stage/init"
mkdir -p "$stage/proc" "$stage/sys" "$stage/dev" "$stage/mnt"
mkdir -m 0777 -p "$stage/tmp"

cpio_err=$(mktemp "$BUILD_DIR/cpio-err.XXXXXX")
( cd "$stage" && find . | LC_ALL=C sort | cpio -o --format newc -R 0:0 ) > "$OUT.part" 2>"$cpio_err"
mv "$OUT.part" "$OUT"
grep -vE '^[0-9]+ blocks?$' "$cpio_err" >&2 || true
rm -f "$cpio_err"

rm -rf "$stage"
trap - EXIT INT TERM

echo "mk-builder-initramfs: wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
