# msl M0 root build: kernel + guest agent + host VMM, packaged into an
# initramfs and driven by a code-signed `msl boot` smoke test.

GUEST_DIR    := guest
HOST_DIR     := host
KERNEL_DIR   := kernel
BUILD_DIR    := build
VERSION      ?= 0.1.0
MSL_TEAM_ID  ?=

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
PKG_ROOT     := $(BUILD_DIR)/pkgroot
PKG_COMPONENT := $(BUILD_DIR)/msl-component.pkg
PKG_PRODUCT  := $(BUILD_DIR)/msl-$(VERSION).pkg
PKG_COMPONENT_PLIST := packaging/component.plist
SKILL_ARCHIVE := $(BUILD_DIR)/msl-agent-skill-$(VERSION).tar.gz
CONSOLE_LOG  := $(BUILD_DIR)/console.log
ENTITLEMENTS ?= entitlements/dev.entitlements
RELEASE_ENTITLEMENTS := entitlements/release.entitlements
SIGN_OPTIONS ?= --timestamp=none
RELEASE_APP_SIGN_IDENTITY ?= Developer ID Application
RELEASE_INSTALLER_SIGN_IDENTITY ?= Developer ID Installer
NOTARYTOOL_ARGS ?=

-include .env

ifeq ($(MSL_TEAM_ID),)
MSL_TEAM_ID := $(APPLE_TEAM_ID)
endif

# FSKit appex (ADR 0009): the sole real-cert-signed product. The appex bundle
# ID nests under the menu-bar app's dev.msl.app; the executable is msl-fskit.
# Built by xcodebuild, not SwiftPM: a hand-wrapped SwiftPM executable is not a
# working ExtensionKit extension on macOS 26 (AppExtension.main() returns instead
# of running the service loop). host/fskit-appex.yml is the xcodegen spec.
FSKIT_APPEX_ID    := dev.msl.app.fsmodule
FSKIT_APPEX_DIR   := $(APP_DIR)/Contents/Extensions/$(FSKIT_APPEX_ID).appex
FSKIT_XC_SPEC     := fskit-appex.yml
FSKIT_XC_PROJECT  := $(HOST_DIR)/msl-fskit.xcodeproj
FSKIT_XC_APPEX    := $(HOST_DIR)/.xcbuild/Build/Products/Release/msl-fskit.appex
FSKIT_ENT_SRC     := entitlements/fskit-appex.entitlements
FSKIT_ENT_RENDER  := $(BUILD_DIR)/fskit-appex.entitlements
MSL_APP_GROUP_ID  ?= group.dev.msl.app
# Real Apple Development identity by default; pass FSKIT_SIGN_IDENTITY=- to
# ad-hoc sign for CI (the appex builds but AMFI blocks its load without the
# restricted entitlement's provisioning profile).
FSKIT_SIGN_IDENTITY     ?= Apple Development
# Optional: path to embedded.provisionprofile authorizing fskit.fsmodule +
# the app group. Required for the appex to actually load, not to build/sign.
FSKIT_PROVISION_PROFILE ?=

# The FSKit appex is hosted by its container app: ExtensionKit will not load an
# extension whose container is ad-hoc signed while the extension is team signed
# (fails with "file system named mslfs not found" / extensionKit error 2). So an
# FSKit-enabled build (a profile is provided) team-signs the whole app; the
# no-account build stays ad-hoc and simply has no working FSKit view.
ifeq ($(FSKIT_PROVISION_PROFILE),)
APP_SIGN_IDENTITY := -
else
APP_SIGN_IDENTITY := $(FSKIT_SIGN_IDENTITY)
endif

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "msl M0 targets:"; \
	echo "  make guest      - build the aarch64-musl guest agent (excludes msl-way)"; \
	echo "  make xkb        - cross-build the static libxkbcommon for msl-way"; \
	echo "  make msl-way    - build the aarch64-musl msl-way GUI compositor (needs xkb)"; \
	echo "  make host       - build the host msl VMM (release)"; \
	echo "  make sign       - codesign msl with the virtualization entitlement"; \
	echo "  make app        - assemble msl.app (menu-bar app + bundled CLI + FSKit appex)"; \
	echo "  make packaging-test - run pkg script unit tests"; \
	echo "  make release-pkg - build a signed Developer ID pkg at $(PKG_PRODUCT)"; \
	echo "  make skill-archive - build $(SKILL_ARCHIVE)"; \
	echo "  make notarize   - submit, staple, and verify $(PKG_PRODUCT)"; \
	echo "  make appex      - assemble+sign the FSKit appex into an existing msl.app"; \
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
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"; \
	cp "$(MENUBAR_BIN)" "$(APP_DIR)/Contents/MacOS/msl-menubar"; \
	cp "$(HOST_BIN)" "$(APP_DIR)/Contents/MacOS/msl"; \
	cp "$(APP_PLIST)" "$(APP_DIR)/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	  "$(APP_DIR)/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" \
	  "$(APP_DIR)/Contents/Info.plist"; \
	if [ -n "$(MSL_TEAM_ID)" ]; then \
	  /usr/libexec/PlistBuddy -c "Add :MSLTeamID string $(MSL_TEAM_ID)" \
	    "$(APP_DIR)/Contents/Info.plist" 2>/dev/null || \
	    /usr/libexec/PlistBuddy -c "Set :MSLTeamID $(MSL_TEAM_ID)" \
	    "$(APP_DIR)/Contents/Info.plist"; \
	fi; \
	cp LICENSE NOTICE THIRD-PARTY-LICENSES "$(APP_DIR)/Contents/Resources/"; \
	if [ -f "$(KERNEL_IMAGE)" ]; then cp "$(KERNEL_IMAGE)" "$(APP_DIR)/Contents/Resources/kernel"; fi; \
	if [ -f "$(INITRAMFS)" ]; then cp "$(INITRAMFS)" "$(APP_DIR)/Contents/Resources/initramfs.cpio"; fi; \
	if [ -f "$(BUILDER_INITRAMFS)" ]; then cp "$(BUILDER_INITRAMFS)" "$(APP_DIR)/Contents/Resources/builder-initramfs.cpio"; fi; \
	plutil -lint "$(APP_DIR)/Contents/Info.plist"; \
	if [ -n "$(FSKIT_PROVISION_PROFILE)" ]; then \
	  $(MAKE) appex; \
	else \
	  echo "app: no FSKIT_PROVISION_PROFILE — skipping FSKit appex (no Finder view; needs xcodegen + a profile)"; \
	fi; \
	codesign --force $(SIGN_OPTIONS) --sign "$(APP_SIGN_IDENTITY)" \
	  --entitlements "$(ENTITLEMENTS)" "$(APP_DIR)/Contents/MacOS/msl"; \
	codesign --force $(SIGN_OPTIONS) --sign "$(APP_SIGN_IDENTITY)" \
	  --entitlements "$(ENTITLEMENTS)" "$(APP_DIR)/Contents/MacOS/msl-menubar"; \
	codesign --force $(SIGN_OPTIONS) --sign "$(APP_SIGN_IDENTITY)" \
	  --entitlements "$(ENTITLEMENTS)" "$(APP_DIR)"; \
	codesign --verify --strict "$(APP_DIR)"; \
	echo "app: assembled $(APP_DIR) (identity: $(APP_SIGN_IDENTITY))"

# Build the FSKit appex as a real Xcode extensionkit-extension, embed it in the
# app bundle, and sign it. The app group is rendered into both the appex
# Info.plist and the entitlements so no generated file is committed. The appex is
# the only real-cert product; the app bundle seal (signed last, in `app`) covers
# it by cdhash. Needs xcodegen (brew install xcodegen) and full Xcode.
.PHONY: appex
appex:
	@set -eu; \
	command -v xcodegen >/dev/null 2>&1 || { \
	  echo "appex: xcodegen not found (brew install xcodegen)" >&2; exit 1; }; \
	if [ ! -d "$(APP_DIR)/Contents" ]; then \
	  echo "appex: $(APP_DIR) not assembled; run 'make app'" >&2; exit 1; \
	fi; \
	( cd "$(HOST_DIR)" && xcodegen generate --spec "$(FSKIT_XC_SPEC)" --quiet ); \
	( cd "$(HOST_DIR)" && xcodebuild -project msl-fskit.xcodeproj -scheme msl-fskit \
	  -configuration Release -derivedDataPath .xcbuild -destination 'generic/platform=macOS' \
	  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet build ); \
	rm -rf "$(FSKIT_APPEX_DIR)"; \
	mkdir -p "$(APP_DIR)/Contents/Extensions"; \
	cp -R "$(FSKIT_XC_APPEX)" "$(FSKIT_APPEX_DIR)"; \
	/usr/libexec/PlistBuddy -c "Set :MSLAppGroup $(MSL_APP_GROUP_ID)" \
	  "$(FSKIT_APPEX_DIR)/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	  "$(FSKIT_APPEX_DIR)/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" \
	  "$(FSKIT_APPEX_DIR)/Contents/Info.plist"; \
	plutil -lint "$(FSKIT_APPEX_DIR)/Contents/Info.plist"; \
	mkdir -p "$(BUILD_DIR)"; \
	cp "$(FSKIT_ENT_SRC)" "$(FSKIT_ENT_RENDER)"; \
	/usr/libexec/PlistBuddy -c \
	  "Set :com.apple.security.application-groups:0 $(MSL_APP_GROUP_ID)" \
	  "$(FSKIT_ENT_RENDER)"; \
	if [ -n "$(MSL_TEAM_ID)" ]; then \
	  /usr/libexec/PlistBuddy -c \
	    "Add :com.apple.application-identifier string $(MSL_TEAM_ID).$(FSKIT_APPEX_ID)" \
	    "$(FSKIT_ENT_RENDER)" 2>/dev/null || \
	    /usr/libexec/PlistBuddy -c \
	    "Set :com.apple.application-identifier $(MSL_TEAM_ID).$(FSKIT_APPEX_ID)" \
	    "$(FSKIT_ENT_RENDER)"; \
	  /usr/libexec/PlistBuddy -c \
	    "Add :com.apple.developer.team-identifier string $(MSL_TEAM_ID)" \
	    "$(FSKIT_ENT_RENDER)" 2>/dev/null || \
	    /usr/libexec/PlistBuddy -c \
	    "Set :com.apple.developer.team-identifier $(MSL_TEAM_ID)" \
	    "$(FSKIT_ENT_RENDER)"; \
	  /usr/libexec/PlistBuddy -c \
	    "Add :com.apple.security.application-groups:1 string $(MSL_TEAM_ID).*" \
	    "$(FSKIT_ENT_RENDER)" 2>/dev/null || true; \
	  /usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" \
	    "$(FSKIT_ENT_RENDER)" 2>/dev/null || true; \
	  /usr/libexec/PlistBuddy -c \
	    "Add :keychain-access-groups:0 string $(MSL_TEAM_ID).*" \
	    "$(FSKIT_ENT_RENDER)" 2>/dev/null || true; \
	fi; \
	plutil -lint "$(FSKIT_ENT_RENDER)"; \
	if [ -n "$(FSKIT_PROVISION_PROFILE)" ]; then \
	  if [ ! -f "$(FSKIT_PROVISION_PROFILE)" ]; then \
	    echo "appex: FSKIT_PROVISION_PROFILE=$(FSKIT_PROVISION_PROFILE) not found" >&2; exit 1; \
	  fi; \
	  cp "$(FSKIT_PROVISION_PROFILE)" "$(FSKIT_APPEX_DIR)/Contents/embedded.provisionprofile"; \
	  echo "appex: embedded provisioning profile"; \
	else \
	  echo "appex: no FSKIT_PROVISION_PROFILE; appex will sign but AMFI blocks load until one is embedded" >&2; \
	fi; \
	codesign --force $(SIGN_OPTIONS) --sign "$(FSKIT_SIGN_IDENTITY)" \
	  --entitlements "$(FSKIT_ENT_RENDER)" "$(FSKIT_APPEX_DIR)"; \
	codesign --verify --strict "$(FSKIT_APPEX_DIR)"; \
	echo "appex: signed $(FSKIT_APPEX_DIR) (identity: $(FSKIT_SIGN_IDENTITY), group: $(MSL_APP_GROUP_ID))"

.PHONY: release-runtime
release-runtime: kernel guest msl-way
	@set -eu; \
	REQUIRE_MSL_WAY=1 tools/mk-initramfs.sh; \
	tools/mk-builder-initramfs.sh

.PHONY: packaging-test
packaging-test:
	@set -eu; \
	packaging/tests/postinstall_test.sh

.PHONY: skill-archive
skill-archive:
	@set -eu; \
	rm -f "$(SKILL_ARCHIVE)"; \
	mkdir -p "$(BUILD_DIR)"; \
	tar -czf "$(SKILL_ARCHIVE)" -C packaging/agent-skill msl; \
	shasum -a 256 "$(SKILL_ARCHIVE)" >"$(SKILL_ARCHIVE).sha256"; \
	echo "skill-archive: wrote $(SKILL_ARCHIVE)"

.PHONY: release-app
release-app:
	@set -eu; \
	if [ -z "$(FSKIT_PROVISION_PROFILE)" ]; then \
	  echo "release-app: FSKIT_PROVISION_PROFILE is required" >&2; exit 1; \
	fi; \
	if [ ! -f "$(FSKIT_PROVISION_PROFILE)" ]; then \
	  echo "release-app: FSKIT_PROVISION_PROFILE=$(FSKIT_PROVISION_PROFILE) not found" >&2; exit 1; \
	fi; \
	if [ -z "$(MSL_TEAM_ID)" ]; then \
	  echo "release-app: MSL_TEAM_ID is required" >&2; exit 1; \
	fi; \
	$(MAKE) release-runtime; \
	$(MAKE) app \
	  ENTITLEMENTS="$(RELEASE_ENTITLEMENTS)" \
	  SIGN_OPTIONS="--options runtime --timestamp" \
	  APP_SIGN_IDENTITY="$(RELEASE_APP_SIGN_IDENTITY)" \
	  FSKIT_SIGN_IDENTITY="$(RELEASE_APP_SIGN_IDENTITY)" \
	  MSL_TEAM_ID="$(MSL_TEAM_ID)" \
	  FSKIT_PROVISION_PROFILE="$(FSKIT_PROVISION_PROFILE)"; \
	for f in \
	  "$(APP_DIR)/Contents/MacOS/msl" \
	  "$(APP_DIR)/Contents/MacOS/msl-menubar" \
	  "$(FSKIT_APPEX_DIR)" \
	  "$(APP_DIR)"; do \
	  codesign --verify --strict "$$f"; \
	done; \
	test -f "$(APP_DIR)/Contents/Resources/kernel"; \
	test -f "$(APP_DIR)/Contents/Resources/initramfs.cpio"; \
	test -f "$(APP_DIR)/Contents/Resources/builder-initramfs.cpio"

.PHONY: release-pkg
release-pkg: release-app skill-archive
	@set -eu; \
	rm -rf "$(PKG_ROOT)" "$(PKG_COMPONENT)" "$(PKG_PRODUCT)"; \
	mkdir -p "$(PKG_ROOT)/Applications" "$(PKG_ROOT)/usr/local/bin"; \
	/usr/bin/ditto "$(APP_DIR)" "$(PKG_ROOT)/Applications/msl.app"; \
	{ \
	  echo '#!/bin/sh'; \
	  echo 'export MSL_FSKIT_TEAM_ID="$(MSL_TEAM_ID)"'; \
	  echo 'exec /Applications/msl.app/Contents/MacOS/msl "$$@"'; \
	} >"$(PKG_ROOT)/usr/local/bin/msl"; \
	chmod 0755 "$(PKG_ROOT)/usr/local/bin/msl"; \
	pkgbuild --root "$(PKG_ROOT)" --component-plist "$(PKG_COMPONENT_PLIST)" \
	  --scripts packaging/scripts \
	  --identifier dev.msl.pkg --version "$(VERSION)" --install-location / \
	  "$(PKG_COMPONENT)"; \
	productbuild --package "$(PKG_COMPONENT)" --sign "$(RELEASE_INSTALLER_SIGN_IDENTITY)" \
	  "$(PKG_PRODUCT)"; \
	pkgutil --check-signature "$(PKG_PRODUCT)"; \
	shasum -a 256 "$(PKG_PRODUCT)" >"$(PKG_PRODUCT).sha256"; \
	echo "release-pkg: wrote $(PKG_PRODUCT)"

.PHONY: notarize
notarize: release-pkg
	@set -eu; \
	if [ -z "$(NOTARYTOOL_ARGS)" ]; then \
	  echo "notarize: set NOTARYTOOL_ARGS for xcrun notarytool submit" >&2; exit 1; \
	fi; \
	xcrun notarytool submit "$(PKG_PRODUCT)" $(NOTARYTOOL_ARGS) --wait; \
	xcrun stapler staple "$(PKG_PRODUCT)"; \
	xcrun stapler validate "$(PKG_PRODUCT)"; \
	spctl --assess --type install "$(PKG_PRODUCT)"; \
	shasum -a 256 "$(PKG_PRODUCT)" >"$(PKG_PRODUCT).sha256"; \
	echo "notarize: stapled $(PKG_PRODUCT)"

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
