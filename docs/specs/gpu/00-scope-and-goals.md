# 00 — Scope and Goals

## Problem statement

msl presents Linux GUI applications in native macOS windows through the
`msl-way` compositor and the `msl-presenter` AppKit process. Today the entire
pixel pipeline is software: guest apps render with llvmpipe
(`LIBGL_ALWAYS_SOFTWARE=1`, `MESA_LOADER_DRIVER_OVERRIDE=llvmpipe` — set in
`guest/agent/src/gui.rs:568-572` and mirrored in
`host/Sources/MSLCore/GuiRuntime.swift:26-27`), the compositor copies client
`wl_shm` buffers on the CPU, and raw BGRA damage rectangles cross vsock port
5020 to be memcpy'd into an IOSurface.

This is correct but cannot serve the target use case: **testing GPU-rendered
applications inside the subsystem**. Vulkan apps do not run at all (no GPU
device, no ICD beyond lavapipe), GL apps run at llvmpipe speed, and anything
that assumes `/dev/dri` fails. The root cause is the virtualization layer:
Apple's Virtualization.framework exposes no 3D acceleration path for Linux
guests (verified — see 02-research-findings.md §1), so no amount of guest-side
work can fix this while msl is VZ-only.

## Goals

G-1. **Run GPU-rendered Linux apps.** A Vulkan application (`vkcube`,
     `vkmark`, a Vulkan game, a Vulkan-compute workload) launched in an msl
     distro renders on the Apple GPU and presents into a native macOS window
     through msl-way/msl-presenter.

G-2. **Run OpenGL apps with acceleration.** GL/GLES applications (glmark2,
     GTK4/Qt6 apps with GL renderers, `glxgears`) render through
     Zink-on-Venus (or ANGLE-on-Venus for GLES) instead of llvmpipe.

G-3. **Preserve the msl UX contract.** Named distros, instant shells, faithful
     exit codes, `/mnt/mac`, localhost mirroring, `mac` interop, FSKit mounts,
     `.msl` bundles, launchers — all keep working for every distro regardless
     of which backend hosts it.

G-4. **Preserve Rosetta.** Rosetta is architecturally locked to
     Virtualization.framework (02-research-findings.md §5). Distros with
     Rosetta enabled must keep working exactly as today.

G-5. **Zero-copy where it matters.** The end state presents client GPU buffers
     into CALayers without a CPU round trip (IOSurface handoff). An interim
     copy-based stage is acceptable as a correctness milestone.

G-6. **Shippable.** Everything bundles into the signed/notarized `.pkg`
     (permissively-licensed host dependencies only; GPL stays confined to the
     kernel submodule as today), builds in CI on `macos-26` runners, and
     degrades gracefully on machines/OS versions where the GPU path is
     unavailable.

## Non-goals (this program)

- **Windows-style D3D translation** (WSLg/DXVK parity). Out of scope; Vulkan
  and GL are the targets. DXVK-on-Venus may fall out for free later but is
  not gated on.
- **GPU compute passthrough for CUDA/ROCm.** Non-existent on Apple hardware.
  Vulkan compute works via Venus; that is the offer.
- **Audio.** libkrun has no macOS audio backend today; msl has no audio today.
  Tracked in 16-future-work.md, not gated.
- **Replacing the VZ backend entirely.** VZ remains for Rosetta and as the
  conservative default until the krun backend earns default status
  (12-milestone-g7 §policy).
- **x86-64 GPU distros.** Rosetta (x86-64) and GPU are mutually exclusive per
  distro in this program. FEX-on-krun is future work (16-future-work.md).
- **Multi-host/remote display, VM snapshots, nested virt on the GPU VM.**

## Hard requirements the new backend must meet

Derived from the as-is architecture (01-current-architecture.md). Any
replacement VMM must provide:

| # | Requirement | Why |
|---|---|---|
| R1 | virtio-vsock with host-side per-port connect **and** guest-initiated (reverse) connections | Entire host↔guest control surface: ports 5000/5001/5002/5003/5010/5020/5030/5040 (`host/Sources/MSLCore/Proto.swift`, `GuiProto.swift`, `MSLFSWire/FSProto.swift`) |
| R2 | virtio-fs directory shares with tags (`mac`, `staging`) | `/mnt/mac` home sharing, install/export staging (`VMMachine.swift:266-284`, `guest/agent/src/main.rs` `mount_shares`) |
| R3 | virtio-blk, ≥16 disks, raw images | one ext4 image per distro, up to 16 concurrent distros (`VMMachine.swift:249-264`, `guest/agent/src/distro.rs:4`) |
| R4 | Direct kernel boot of an arm64 `Image` + external or embedded initramfs, custom cmdline | msl-agent is PID 1 of the initramfs; no bootloader/EFI in the trust chain today (`VMMachine.swift:195-197`) |
| R5 | Outbound NAT-equivalent networking | distro package managers; inbound is handled by vsock port-forwarding, not the NIC (`PortForwarder.swift`) |
| R6 | Memory reclaim mechanism | daemon memory ladder + balloon (`VMMachine.swift:212-214,221-238`); free-page reporting is an acceptable substitute with G7 adaptation |
| R7 | virtio-gpu with Venus context type, blob resources (`HOST3D`, host-visible mapping), fencing with per-context rings | the entire point |
| R8 | Embeddable/controllable from the Swift daemon; signable with self-serve entitlements | daemon owns VM lifecycle; Developer ID distribution (`entitlements/*`, Makefile `sign`/`release-app`) |
| R9 | Permissive licensing for everything shipped in the app bundle | Apache-2.0 project; GPL isolated to kernel submodule (`README.md` license section) |

Requirement R4 has one sanctioned deviation: the krun backend may embed the
initramfs in the kernel image (`CONFIG_INITRAMFS_SOURCE`) if external-initramfs
support in libkrun is not usable — see 07-milestone-g2 §initramfs.

## Success criteria (program level)

1. `msl install ubuntu && msl config ubuntu --gpu on && msl run ubuntu -- vkcube`
   opens a native macOS window rendering at ≥ 60 fps on an M-series Mac.
2. `vulkaninfo` in a GPU distro reports a Venus device (Vulkan ≥ 1.2); `glxinfo`
   reports Zink (GL ≥ 3.3 with KosmicKrisp host ICD; ≥ 2.1 with MoltenVK).
3. glmark2 (Wayland, fullscreen-windowed) improves ≥ 5× over the llvmpipe
   baseline recorded in G0; GuiLedger p95 commit→present latency for a GPU
   app is ≤ the current SHM path's p95 for equivalent window sizes.
4. All existing e2e surfaces (shell/run/exit codes, port mirroring, FSKit
   read/write harness, Rosetta distro on the VZ VM, GUI SHM path for non-GPU
   distros) pass unchanged.
5. `make release-pkg` produces a notarizable package containing both backends,
   with `THIRD-PARTY-LICENSES` regenerated to cover the new dependencies.
