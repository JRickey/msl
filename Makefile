# msl M0 root build: kernel + guest agent + host VMM, packaged into an
# initramfs and driven by a code-signed `msl boot` smoke test.

GUEST_DIR    := guest
HOST_DIR     := host
KERNEL_DIR   := kernel
BUILD_DIR    := build

GUEST_TARGET := aarch64-unknown-linux-musl
GUEST_BIN    := $(GUEST_DIR)/target/$(GUEST_TARGET)/release/msl-agent
WAY_BIN      := $(GUEST_DIR)/target/$(GUEST_TARGET)/release/msl-way
XKB_MUSL_LIB := $(GUEST_DIR)/target/xkb-musl/libxkbcommon.a
HOST_BIN     := $(HOST_DIR)/.build/release/msl
MENUBAR_BIN  := $(HOST_DIR)/.build/release/msl-menubar
APP_DIR      := $(BUILD_DIR)/msl.app
APP_PLIST    := $(HOST_DIR)/Resources/msl-menubar/Info.plist
KERNEL_IMAGE := $(KERNEL_DIR)/build/Image
INITRAMFS    := $(BUILD_DIR)/initramfs.cpio
BUILDER_INITRAMFS := $(BUILD_DIR)/builder-initramfs.cpio
ROOTFS_IMG   := $(BUILD_DIR)/ubuntu.img
CONSOLE_LOG  := $(BUILD_DIR)/console.log
ENTITLEMENTS := entitlements/dev.entitlements

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "msl M0 targets:"; \
	echo "  make guest      - build the aarch64-musl guest agent (excludes msl-way)"; \
	echo "  make xkb        - cross-build the static libxkbcommon for msl-way"; \
	echo "  make msl-way    - build the aarch64-musl msl-way GUI compositor (needs xkb)"; \
	echo "  make host       - build the host msl VMM (release)"; \
	echo "  make sign       - codesign msl with the virtualization entitlement"; \
	echo "  make app        - assemble msl.app (menu-bar app + bundled CLI)"; \
	echo "  make kernel     - fetch the pinned arm64 kernel Image"; \
	echo "  make initramfs  - assemble $(INITRAMFS) (needs guest)"; \
	echo "  make builder-initramfs - assemble $(BUILDER_INITRAMFS) (needs guest)"; \
	echo "  make rootfs     - build $(ROOTFS_IMG) in the builder VM (MSL_REBUILD_ROOTFS=1 forces)"; \
	echo "  make all        - kernel guest host sign initramfs"; \
	echo "  make smoke      - boot the VM and assert 'echo m0-ok' works"; \
	echo "  make clean      - remove $(BUILD_DIR)/ and per-subtree build outputs"

.PHONY: guest
guest:
	@set -eu; \
	cd "$(GUEST_DIR)"; \
	cargo zigbuild --target "$(GUEST_TARGET)" --release --workspace --exclude msl-way

# Static libxkbcommon for msl-way (idempotent; the script skips when the .a exists).
$(XKB_MUSL_LIB): tools/mk-libxkbcommon.sh
	@set -eu; \
	tools/mk-libxkbcommon.sh

.PHONY: xkb
xkb: $(XKB_MUSL_LIB)

# msl-way links the static libxkbcommon via a -L search path; the agent build
# above stays untouched (msl-way is excluded from the default guest target).
.PHONY: msl-way
msl-way: $(XKB_MUSL_LIB)
	@set -eu; \
	cd "$(GUEST_DIR)"; \
	RUSTFLAGS="-L native=target/xkb-musl" \
	  cargo zigbuild --target "$(GUEST_TARGET)" --release -p msl-way

.PHONY: host
host:
	@set -eu; \
	cd "$(HOST_DIR)"; \
	swift build -c release

.PHONY: sign
sign:
	@set -eu; \
	if [ ! -f "$(HOST_BIN)" ]; then \
	  echo "sign: $(HOST_BIN) missing; run 'make host' first" >&2; \
	  exit 1; \
	fi; \
	codesign --force --sign - --entitlements "$(ENTITLEMENTS)" "$(HOST_BIN)"; \
	echo "sign: signed $(HOST_BIN)"

# Assemble the distributable app bundle: the menu-bar executable plus a copy of
# the CLI, both signed with the virtualization entitlement so the in-process
# InstallDriver builder VM works. Signing the bundle with the same entitlements
# reseals the main executable; the nested CLI keeps its own signature.
.PHONY: app
app: host sign
	@set -eu; \
	if [ ! -f "$(MENUBAR_BIN)" ]; then \
	  echo "app: $(MENUBAR_BIN) missing; run 'make host' first" >&2; exit 1; \
	fi; \
	if [ ! -f "$(HOST_BIN)" ]; then \
	  echo "app: $(HOST_BIN) missing; run 'make host' first" >&2; exit 1; \
	fi; \
	rm -rf "$(APP_DIR)"; \
	mkdir -p "$(APP_DIR)/Contents/MacOS"; \
	cp "$(MENUBAR_BIN)" "$(APP_DIR)/Contents/MacOS/msl-menubar"; \
	cp "$(HOST_BIN)" "$(APP_DIR)/Contents/MacOS/msl"; \
	cp "$(APP_PLIST)" "$(APP_DIR)/Contents/Info.plist"; \
	plutil -lint "$(APP_DIR)/Contents/Info.plist"; \
	codesign --force --sign - --entitlements "$(ENTITLEMENTS)" \
	  "$(APP_DIR)/Contents/MacOS/msl-menubar"; \
	codesign --force --sign - --entitlements "$(ENTITLEMENTS)" "$(APP_DIR)"; \
	codesign --verify --strict "$(APP_DIR)"; \
	echo "app: assembled $(APP_DIR)"

.PHONY: kernel
kernel:
	@set -eu; \
	$(MAKE) -C "$(KERNEL_DIR)" fetch

# Real file targets: `guest` is phony (cargo owns incremental rebuilds), so the
# cpio always regenerates, but consumers can now depend on the concrete file.
$(INITRAMFS): guest tools/mk-initramfs.sh
	@set -eu; \
	tools/mk-initramfs.sh

$(BUILDER_INITRAMFS): guest tools/mk-builder-initramfs.sh
	@set -eu; \
	tools/mk-builder-initramfs.sh

.PHONY: initramfs
initramfs: $(INITRAMFS)

.PHONY: builder-initramfs
builder-initramfs: $(BUILDER_INITRAMFS)

.PHONY: rootfs
rootfs: kernel host sign $(BUILDER_INITRAMFS)
	@set -eu; \
	if [ -f "$(ROOTFS_IMG)" ] && [ -z "$${MSL_REBUILD_ROOTFS:-}" ]; then \
	  echo "rootfs: $(ROOTFS_IMG) exists; skip (MSL_REBUILD_ROOTFS=1 forces)"; \
	else \
	  tools/mk-rootfs.sh; \
	fi

.PHONY: all
all: kernel guest host sign $(INITRAMFS)

.PHONY: smoke
smoke: all
	@set -eu; \
	if [ ! -f "$(KERNEL_IMAGE)" ]; then echo "smoke: missing $(KERNEL_IMAGE)" >&2; exit 1; fi; \
	if [ ! -f "$(INITRAMFS)" ]; then echo "smoke: missing $(INITRAMFS)" >&2; exit 1; fi; \
	mkdir -p "$(BUILD_DIR)"; \
	log="$(BUILD_DIR)/smoke.out"; \
	rc=0; \
	"$(HOST_BIN)" boot \
	  --kernel "$(KERNEL_IMAGE)" \
	  --initramfs "$(INITRAMFS)" \
	  --exec 'echo m0-ok' \
	  --console-log "$(CONSOLE_LOG)" \
	  --timeout 60 >"$$log" 2>&1 || rc=$$?; \
	cat "$$log"; \
	if [ "$$rc" -ne 0 ]; then echo "smoke: msl exited $$rc" >&2; exit 1; fi; \
	if ! grep -q 'm0-ok' "$$log"; then \
	  echo "smoke: FAIL - 'm0-ok' not found in guest output" >&2; \
	  exit 1; \
	fi; \
	echo "smoke: OK (m0-ok, exit 0)"

.PHONY: clean
clean:
	@set -eu; \
	rm -rf "$(BUILD_DIR)"; \
	( cd "$(GUEST_DIR)" && cargo clean ); \
	( cd "$(HOST_DIR)" && swift package clean ); \
	echo "clean: removed $(BUILD_DIR)/ and cleaned guest/host build outputs"
