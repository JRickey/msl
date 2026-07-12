# 07 — Milestone G2: Self-built Kernel with virtio-gpu

Goal: implement the msl-kernel submodule's `make build` target (the stub that
already points at this spec tree) so msl ships a kernel with virtio-gpu and
modern sync primitives, replacing the fetched Kata image for at least the
GPU VM. Work happens in the **msl-kernel repository** (GPLv2 side) plus small
Makefile glue here.

## Entry criteria

- G0.1 passed (so we know exactly which guest kernel features Venus exercised
  in the spike; the spike guest's `config.gz` is a reference artifact).

## Facts and constraints

- Today: `make fetch` downloads Kata 3.17.0's `vmlinux-6.12.28-153` (flat
  arm64 `Image`, sha-pinned) — see kernel submodule Makefile. No config in
  repo. The apple/containerization sibling config (same lineage) has
  `# CONFIG_DRM_VIRTIO_GPU is not set`; **assume the Kata image cannot drive
  virtio-gpu** (verify in G2.1 anyway — if it unexpectedly can, the VZ VM can
  keep the fetched kernel while the GPU VM uses ours, or both move to ours).
- `VZLinuxBootLoader` requires an uncompressed arm64 `Image` (what we already
  ship). libkrun 2.0 `krun_set_kernel` accepts raw/Image formats; libkrun 1.x
  boots either the bundled libkrunfw kernel or EFI. **Plan of record for the
  GPU VM: direct kernel boot with our Image via `krun_set_kernel`** (G3
  vendors a libkrun snapshot where this API exists/backported); EFI is the
  documented fallback (requires bootable disk layout — avoid).
- Guest features Venus/msl-way need (02 §7): DRM + VIRTIO_GPU + GEM shmem,
  blob resources/host-visible (device-side; kernel driver in 6.12 supports
  all required params), syncobj/timeline (6.6+ → 6.12 fine), SYNC_FILE,
  DMA_BUF ioctls (EXPORT/IMPORT_SYNC_FILE, 6.0+), udmabuf (optional).
- Both VMs should converge on the same kernel source/version to keep one
  submodule pin. Kata's 6.12.x LTS line is the base.

## Page-size question (resolve during G2, default given)

Apple Silicon host pages are 16 KiB. Venus host-blob mappings must be
16 KiB-aligned on the host; guest Mesa patches (slp COPR, UTM) currently
paper over guest-4K/host-16K mismatches, and newer kernels expose
`VIRTGPU_PARAM_BLOB_ALIGNMENT` so userspace can honor device alignment.

- **Default: keep `CONFIG_ARM64_4K_PAGES` for both profiles.** Rationale:
  Rosetta requires 4K (VZ VM); distro userland compatibility is maximal; the
  pinned msl Mesa (G4) carries the alignment patch, which is sufficient in
  practice (it is what every shipping krunkit deployment does).
- Keep `ARM64_16K_PAGES` as a documented experiment (`make build
  PROFILE=gpu-16k`) if G4 hits alignment bugs; a 16K GPU-VM kernel removes
  the mismatch class entirely at the cost of a second kernel binary and
  rare userland 4K assumptions.

## Work items (msl-kernel repo unless noted)

### G2.1 — Baseline extraction + verification
Extract the Kata image's config (`extract-ikconfig` if enabled, else boot it
and read `/proc/config.gz`; else fetch Kata's kernel build config for
6.12.28) and commit it as `configs/baseline-kata-6.12.28.config` (reference
only). Record whether `CONFIG_DRM_VIRTIO_GPU` is set. Acceptance: file
committed + a `docs/` note of findings.

### G2.2 — Source + build scaffolding
Implement `make build`:
- `KERNEL_VERSION := 6.12.<latest-lts-patch>`, source tarball from
  cdn.kernel.org, sha256-pinned (follow the repo's existing verify style).
- Apply `patches/*.patch` in lexical order (dir exists, empty).
- Build with the standard aarch64 cross/native toolchain. Two supported
  environments, both must work: (a) macOS host with LLVM
  (`make LLVM=1 ARCH=arm64` — kernel 6.12 builds with clang; document brew
  deps: `llvm`, `lld`, `make`, `bison`, `flex`, `openssl@3` headers not
  required for Image), (b) any Linux arm64 box/CI container (the Makefile
  comment's `ssh gpu` remote-build hook can stay as sugar). **An msl distro
  itself is a valid build environment** (dogfood: document
  `msl run -- make -C /mnt/mac/... build`).
- Output: `build/Image` (uncompressed arm64). Keep `make fetch` working as
  the no-toolchain fallback.

### G2.3 — msl config profile
`configs/msl-gpu.config` — start from the containerization/Kata-style minimal
config (baseline from G2.1), then set (non-exhaustive; these are the
load-bearing ones):

```
CONFIG_DRM=y
CONFIG_DRM_VIRTIO_GPU=y
CONFIG_DRM_GEM_SHMEM_HELPER=y
CONFIG_DRM_KMS_HELPER=y
CONFIG_DRM_FBDEV_EMULATION=n        # no console scanout; keep hvc0
CONFIG_SYNC_FILE=y
CONFIG_UDMABUF=y
CONFIG_DMABUF_HEAPS=y               # cheap; future host-visible shm heaps
# already present in Kata lineage but assert:
CONFIG_VIRTIO=y, VIRTIO_PCI=y, VIRTIO_MMIO=y, VIRTIO_BLK=y, VIRTIO_NET=y,
CONFIG_VIRTIO_VSOCKETS=y, VIRTIO_FS=y, FUSE_FS=y, VIRTIO_BALLOON=y,
CONFIG_VIRTIO_INPUT=y (harmless), VSOCKETS=y, EXT4_FS=y, BINFMT_MISC=y,
CONFIG_NAMESPACES/PID_NS/UTS_NS/IPC_NS=y, CGROUPS…
```

Everything `=y` (no modules — matches the no-module initramfs model).
Validation: `scripts/kconfig/merge_config.sh` against the baseline; commit
the resulting full config as `configs/msl-gpu.fullconfig` for
reproducibility. Decide VZ profile: same config (preferred: one Image for
both backends — virtio-gpu driver is inert without the device) unless size
or boot-time regression >10 % appears; then split `msl-vz.config`.

### G2.4 — Initramfs strategy
Options, in preference order:
1. **External initramfs via libkrun direct-kernel boot** (needs
   `krun_set_kernel` + initrd API in the vendored libkrun; verify in G3.1).
   Zero changes to the msl asset pipeline: same `initramfs.cpio` for both
   backends.
2. **Embedded initramfs** for the GPU-VM kernel:
   `CONFIG_INITRAMFS_SOURCE=<path to build/initramfs.cpio>` — the msl repo's
   Makefile passes the cpio path in (`make -C kernel build
   INITRAMFS=…/build/initramfs.cpio`), producing `Image-gpu` whose PID 1 is
   msl-agent as usual. Costs: kernel rebuild on agent change (dev loop:
   `make initramfs && make -C kernel build` — acceptable; document).
Record the choice in this doc when G3.1 lands.

### G2.5 — msl repo glue
- Top-level `Makefile`: `kernel` target grows `KERNEL_MODE=fetch|build`
  (default `fetch` until G9 flips it); `release-runtime` uses `build` once
  CI can (G8 decides where kernel builds happen for release: prebuilt +
  sha-pinned artifact hosted on the msl-kernel repo's releases is the plan,
  mirroring the current Kata fetch pattern — `make fetch` then points at
  *our* release artifact).
- `MSLHome` resolution unchanged (same `kernel` filename). If profiles
  split: `kernel-gpu` alongside `kernel`, `BootSpec` picks by backend, both
  bundled in `Contents/Resources` (app target lines `Makefile:183-185`).

### G2.6 — Boot validation
- VZ smoke: `make smoke` with the self-built Image (asserts m0-ok).
- GPU features present: temporary smoke extension — boot self-built kernel
  (VZ is fine for this check), `grep -q virtio_gpu /proc/modules || test -d
  /sys/module/virtio_gpu` … simpler: `test -e /sys/class/misc/udmabuf` and
  `zcat /proc/config.gz | grep DRM_VIRTIO_GPU=y` (enable
  `CONFIG_IKCONFIG_PROC=y` in the profile to make this testable).
- Under krunkit/libkrun (manual until G3): boot the Image, confirm
  `/dev/dri/renderD128` appears with the venus-capable device.

## Exit criteria

- `make -C kernel build` produces a booting Image from pinned source +
  committed config; `make smoke` green with it.
- Config committed; virtio-gpu + syncobj + sync_file + dmabuf ioctls
  verified present (via IKCONFIG + `/dev/dri` under a virtio-gpu-capable
  VMM).
- Initramfs strategy recorded; msl Makefile glue merged; fetch fallback
  still works.
- License hygiene: all GPL material stays in msl-kernel; the msl repo gains
  no GPL files (config fragments living in msl-kernel, not here).
