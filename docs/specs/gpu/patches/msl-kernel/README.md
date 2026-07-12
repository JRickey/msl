# msl-kernel patch series (milestone G2)

Patches for the **separate `msl-kernel` repository** (the GPLv2 kernel side),
staged here because that repo was not writable from the session that produced
them. They implement milestone G2 of this spec
([07-milestone-g2-kernel.md](../../07-milestone-g2-kernel.md)): the real
`make build` target with a validated virtio-gpu kernel config.

## Applying

```sh
cd kernel                      # the msl-kernel checkout (submodule or clone)
git am path/to/0001-*.patch    # applies cleanly on M0 (commit 7341306)
```

Verified: `git am --3way` applies cleanly on `7341306` (the current submodule
pin) and `scripts/assert-config.sh configs/msl-gpu.config configs/msl-gpu.assert`
passes on the applied tree.

## After applying — the one networked bootstrap step

The series ships **fail-closed**: `configs/linux-6.12.95.tar.xz.sha256` is
deliberately absent because kernel.org was unreachable from the authoring
environment and msl never ships fabricated checksums. On any machine with
kernel.org access:

```sh
make pin      # writes configs/linux-6.12.95.tar.xz.sha256 from the official manifest
git add configs/linux-6.12.95.tar.xz.sha256
git commit -m 'kernel: pin linux-6.12.95.tar.xz'
make build    # now builds; autodetects aarch64-linux-gnu-gcc or clang/LLVM
```

Then push msl-kernel, bump the submodule pin in this repo, and flip
`KERNEL_MODE=build` (top-level Makefile) when ready.

## What was validated at authoring time

Against a real pristine `linux-6.12.95` tree (tag `v6.12.95`):

- Config pipeline end-to-end: baseline copy → `merge_config.sh -m` fragment
  merge (only the four intended overrides warn) → `olddefconfig` → all
  assertions pass → `configs/msl-gpu.config` written; regeneration is stable.
- Full `make build KERNEL_SRC=<tree>` compile with `LLVM=1` (clang): produced
  a bootable-format arm64 Image ("Linux kernel ARM64 boot executable Image,
  4K pages"); `extract-ikconfig` on the built Image confirms
  `CONFIG_DRM_VIRTIO_GPU=y`, `CONFIG_SYNC_FILE=y`, `CONFIG_UDMABUF=y`, and
  modules/fbdev-emulation off.
- Fail-closed path: `make build` without the pin file stops with the
  `make pin` instructions.

Not yet validated (needs macOS hardware / the real repos): VZ + krun boot of
the built Image (`make smoke`, spec G2.6), and `make pin` against live
kernel.org.
