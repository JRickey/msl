# msl M0 root build: kernel + guest agent + host VMM, packaged into an
# initramfs and driven by a code-signed `msl boot` smoke test.

GUEST_DIR    := guest
HOST_DIR     := host
KERNEL_DIR   := kernel
BUILD_DIR    := build

GUEST_TARGET := aarch64-unknown-linux-musl
GUEST_BIN    := $(GUEST_DIR)/target/$(GUEST_TARGET)/release/msl-agent
HOST_BIN     := $(HOST_DIR)/.build/release/msl
KERNEL_IMAGE := $(KERNEL_DIR)/build/Image
INITRAMFS    := $(BUILD_DIR)/initramfs.cpio
CONSOLE_LOG  := $(BUILD_DIR)/console.log
ENTITLEMENTS := entitlements/dev.entitlements

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "msl M0 targets:"; \
	echo "  make guest      - build the aarch64-musl guest agent"; \
	echo "  make host       - build the host msl VMM (release)"; \
	echo "  make sign       - codesign msl with the virtualization entitlement"; \
	echo "  make kernel     - fetch the pinned arm64 kernel Image"; \
	echo "  make initramfs  - assemble $(INITRAMFS) (needs guest)"; \
	echo "  make all        - kernel guest host sign initramfs"; \
	echo "  make smoke      - boot the VM and assert 'echo m0-ok' works"; \
	echo "  make clean      - remove $(BUILD_DIR)/ and per-subtree build outputs"

.PHONY: guest
guest:
	@set -eu; \
	cd "$(GUEST_DIR)"; \
	cargo zigbuild --target "$(GUEST_TARGET)" --release

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

.PHONY: kernel
kernel:
	@set -eu; \
	$(MAKE) -C "$(KERNEL_DIR)" fetch

.PHONY: initramfs
initramfs: guest
	@set -eu; \
	tools/mk-initramfs.sh

.PHONY: all
all: kernel guest host sign initramfs

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
