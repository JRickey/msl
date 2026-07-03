#!/bin/sh
# Build build/ubuntu.img: an ext4 root filesystem populated with the Ubuntu
# 24.04 arm64 cloud rootfs, assembled inside the builder VM (macOS cannot write
# ext4). One boot runs the whole build as a single agent exec; a second boot
# verifies the result.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

BUILD_DIR="$REPO_ROOT/build"
CACHE_DIR="$BUILD_DIR/cache"
STAGING="$BUILD_DIR/staging"
IMG="$BUILD_DIR/ubuntu.img"
CONSOLE_LOG="$BUILD_DIR/builder-console.log"

MSL="$REPO_ROOT/host/.build/release/msl"
KERNEL="$REPO_ROOT/kernel/build/Image"
BUILDER_INITRAMFS="$BUILD_DIR/builder-initramfs.cpio"

ROOTFS_SIZE="${MSL_ROOTFS_SIZE:-8g}"

# Ubuntu 24.04 LTS arm64 cloud-image ROOT tarball, pinned to release serial
# 20260615 (the serial the /release/ current alias resolved to).
UBUNTU_SERIAL="20260615"
UBUNTU_TARBALL="ubuntu-24.04-server-cloudimg-arm64-root.tar.xz"
UBUNTU_URL="https://cloud-images.ubuntu.com/releases/24.04/release-$UBUNTU_SERIAL/$UBUNTU_TARBALL"
UBUNTU_SHA256="15188696da114a3ffd3d3554f5858a0c3ac257933656e85feb4e0e83ad542b4a"

verify_sha256() {
	f="$1"
	want="$2"
	[ -f "$f" ] || return 1
	have=$(shasum -a 256 "$f" | awk '{print $1}')
	[ "$have" = "$want" ]
}

for req in "$MSL" "$KERNEL" "$BUILDER_INITRAMFS"; do
	if [ ! -f "$req" ]; then
		echo "mk-rootfs: missing prerequisite: $req" >&2
		echo "  run 'make all' and 'make builder-initramfs' first" >&2
		exit 1
	fi
done

mkdir -p "$CACHE_DIR"

if ! verify_sha256 "$CACHE_DIR/$UBUNTU_TARBALL" "$UBUNTU_SHA256"; then
	echo "mk-rootfs: fetching $UBUNTU_TARBALL (serial $UBUNTU_SERIAL)"
	curl -fSsL -o "$CACHE_DIR/$UBUNTU_TARBALL.part" "$UBUNTU_URL"
	mv "$CACHE_DIR/$UBUNTU_TARBALL.part" "$CACHE_DIR/$UBUNTU_TARBALL"
	if ! verify_sha256 "$CACHE_DIR/$UBUNTU_TARBALL" "$UBUNTU_SHA256"; then
		echo "ERROR: $UBUNTU_TARBALL sha256 mismatch" >&2
		echo "  expected: $UBUNTU_SHA256" >&2
		echo "  actual:   $(shasum -a 256 "$CACHE_DIR/$UBUNTU_TARBALL" | awk '{print $1}')" >&2
		rm -f "$CACHE_DIR/$UBUNTU_TARBALL"
		exit 1
	fi
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"
ln "$CACHE_DIR/$UBUNTU_TARBALL" "$STAGING/$UBUNTU_TARBALL" 2>/dev/null \
	|| cp "$CACHE_DIR/$UBUNTU_TARBALL" "$STAGING/$UBUNTU_TARBALL"

rm -f "$IMG"
mkfile -n "$ROOTFS_SIZE" "$IMG"
echo "mk-rootfs: created sparse $IMG ($ROOTFS_SIZE)"

BUILD_SCRIPT='set -euf
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
T0=$(date +%s)
echo "builder: mkfs.ext4 /dev/vda"
/sbin/mkfs.ext4 -F -q /dev/vda
echo "builder: [$(($(date +%s)-T0))s] mount"
mount -t ext4 /dev/vda /mnt
echo "builder: [$(($(date +%s)-T0))s] extract '"$UBUNTU_TARBALL"'"
/usr/bin/tar -xJpf /run/msl/staging/'"$UBUNTU_TARBALL"' --xattrs --xattrs-include=* --numeric-owner -C /mnt
echo "builder: [$(($(date +%s)-T0))s] seed"
echo ubuntu > /mnt/etc/hostname
printf "/dev/vda / ext4 defaults 0 1\n" > /mnt/etc/fstab
mkdir -p /mnt/mnt/mac
touch /mnt/etc/cloud/cloud-init.disabled
printf "network:\n  version: 2\n  ethernets:\n    all:\n      match: {name: \"e*\"}\n      dhcp4: true\n" > /mnt/etc/netplan/01-msl.yaml
chmod 600 /mnt/etc/netplan/01-msl.yaml
/usr/sbin/chroot /mnt /usr/bin/passwd -d root
ln -sf /dev/null /mnt/etc/systemd/system/systemd-networkd-wait-online.service
echo "builder: [$(($(date +%s)-T0))s] sync+umount"
sync
umount /mnt
echo "builder: [$(($(date +%s)-T0))s] done"'

echo "mk-rootfs: build boot"
rc=0
"$MSL" boot \
	--kernel "$KERNEL" \
	--initramfs "$BUILDER_INITRAMFS" \
	--disk "$IMG" \
	--share "staging=$STAGING:ro" \
	--exec "$BUILD_SCRIPT" \
	--console-log "$CONSOLE_LOG" \
	--cpus 4 \
	--memory-mib 4096 \
	--timeout 120 || rc=$?
if [ "$rc" -ne 0 ]; then
	echo "mk-rootfs: build boot FAILED (msl exit $rc)" >&2
	echo "--- $CONSOLE_LOG (last 40 lines) ---" >&2
	tail -n 40 "$CONSOLE_LOG" >&2 || true
	exit 1
fi

echo "mk-rootfs: verify boot"
rc=0
"$MSL" boot \
	--kernel "$KERNEL" \
	--initramfs "$BUILDER_INITRAMFS" \
	--disk "$IMG" \
	--exec 'mount -t ext4 /dev/vda /mnt && test -x /mnt/usr/lib/systemd/systemd && test -f /mnt/etc/cloud/cloud-init.disabled && umount /mnt && echo verify-ok' \
	--console-log "$BUILD_DIR/builder-verify-console.log" \
	--timeout 120 || rc=$?
if [ "$rc" -ne 0 ]; then
	echo "mk-rootfs: verify boot FAILED (msl exit $rc)" >&2
	echo "--- builder-verify-console.log (last 40 lines) ---" >&2
	tail -n 40 "$BUILD_DIR/builder-verify-console.log" >&2 || true
	exit 1
fi

rm -rf "$STAGING"
echo "mk-rootfs: wrote $IMG"
