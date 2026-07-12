# 03 — Decision (ADR-GPU-1)

## Status

Accepted (this program's plan of record). Supersedes the README constraint
line "GUI apps use software rendering; correct behavior is the goal before
GPU-class speed" with a concrete acceleration plan.

## Context

- Goal: test GPU-rendered GUI apps inside msl (00-scope-and-goals.md).
- Verified: Virtualization.framework cannot and will not (near-term) provide
  Linux 3D; Apple `container` wontfixed it (02 §1–2).
- Verified: msl's hard requirements are vsock + virtiofs + direct kernel boot
  + Rosetta + permissive licensing (00 §hard requirements).
- Verified: the only shipping, permissively-licensed, macOS GPU path for
  Linux guests is libkrun's virtio-gpu Venus stack; QEMU lacks vsock/virtiofs
  on macOS entirely; Rosetta cannot leave VZ (02 §4–6).

## Options considered

**A. Status quo (VZ + llvmpipe).** Fails the use case. Rejected.

**B. Keep VZ, tunnel a GPU protocol over vsock (vtest-style).**
Structurally impossible: venus/vtest requires SCM_RIGHTS fd passing and
same-kernel mmap of host memory; vsock offers neither; venus additionally
assumes coherent guest mappings of host blobs and shared-memory fence
feedback. Every socket-transport API-remoting system pays a copy + RTT per
mapping/fence and is documented as test-only. Rejected on correctness, not
just performance. (02 §7 "vtest".)

**C. Replace VZ wholesale with QEMU/HVF.** No vsock, no virtiofs on macOS —
both are msl's lifeblood; also loses Rosetta and adds GPL surface. Rejected.
(02 §6.)

**D. Replace VZ wholesale with libkrun.** Gains GPU but loses Rosetta
(hard-locked to VZ) and the mature VZ virtiofs/balloon behavior for everyone,
including users who never use GPU. Rejected as a wholesale swap; accepted as
an *additional* backend.

**E. Write our own VMM on Hypervisor.framework.** Proves out (Parallels,
VMware, Docker VMM all did it) but means re-implementing vsock, virtio-fs,
virtio-blk, virtio-net, virtio-gpu + the venus renderer integration that
libkrun (Apache-2.0, embeddable C API, shipping as podman's default) already
provides. Rejected: no differentiated value for the cost. Revisit only if
libkrun governance/maintenance collapses (15-risks.md R-9).

**F. Keep VZ and implement virtio-gpu via `VZCustomVirtioDeviceConfiguration`
(macOS 27 beta).** The dream end-state: one VM, Rosetta *and* GPU. But the
API is beta, unproven for the queue/shared-memory semantics virtio-gpu blob
mapping needs, macOS 27-only, and would gate the entire program on an OS
that ships ~fall 2026. Deferred: tracked as the **reunification path** in
16-future-work.md, with an explicit re-evaluation gate after G3.

**G. Dual backend: VZ (default, Rosetta) + libkrun (GPU), behind a common
`VMBackend` abstraction. — SELECTED.**

## Decision

1. **Introduce `VMBackend`** (Swift protocol) capturing today's `VMHost`
   surface + capability discovery. `VZBackend` wraps the existing
   implementation unchanged. (G1)
2. **Add a krun backend** implemented as a separate, single-VM child process
   **`msl-vmm`** (Swift executable linking `libkrun` + virglrenderer +
   MoltenVK/KosmicKrisp), because `krun_start_enter()` owns its process. The
   daemon supervises it and speaks to it over a control socket; vsock ports
   surface as unix sockets on the host side. (G3)
3. **Self-build the kernel** in the `msl-kernel` submodule (`make build` —
   the stub already promised this): pinned 6.12.x LTS source + committed
   config fragment enabling virtio-gpu/DRM/syncobj + `patches/`. One kernel
   source, two shipped configs if needed (VZ profile, krun profile). (G2)
4. **Ship guest Mesa ourselves** (Venus ICD + Zink + gbm), built by a new
   `tools/mk-mesa.sh` (zig-cc musl cross like libxkbcommon… or the
   builder-VM native path — G4 decides), staged into the initramfs `/tools`
   and projected into distros at `/run/msl/tools` like every other msl guest
   binary. GPU env replaces the llvmpipe forcing in `gui_env()`/
   `GuiRuntime.env`. (G4)
5. **Extend msl-way + GUI protocol** (still v5 + capability negotiation):
   advertise `zwp_linux_dmabuf_v1`, translate client dmabufs to virtio-gpu
   resource ids, enforce explicit sync (sync_file out-fences; syncobj
   timeline when clients use linux-drm-syncobj-v1), and add a
   resource-reference commit message alongside the pixel commit. SHM path
   remains the universal fallback. (G5)
6. **Host presentation in two stages**: stage 1 — correctness: render →
   `transfer_read`-style copy into the existing IOSurface/CALayer pipeline
   (still GPU-rendered; one copy, same as today's bandwidth). Stage 2 —
   zero-copy: back the guest scanout/client images with IOSurfaces via
   `VK_EXT_metal_objects` in the msl-vmm process and hand IOSurface mach
   ports to `msl-presenter`. (G6)
7. **Daemon orchestrates both VMs** with a per-distro placement policy:
   `msl config <distro> --gpu on|off` (mutually exclusive with
   `--rosetta on`), Rosetta distros pinned to VZ, GPU distros pinned to krun,
   default backend = VZ until the krun path passes G9 acceptance, then
   revisit. (G7)
8. **De-risk first**: G0 spike validates Venus rendering (not just compute),
   Zink-on-Venus GL levels under MoltenVK vs KosmicKrisp, and the
   IOSurface-export recipe, using stock krunkit + a stock Fedora guest —
   before any msl code is written.

## Consequences

Positive:
- GPU-accelerated Vulkan (≈1.2–1.4 class) and GL (2.1 today / 3.3+ with
  KosmicKrisp, trending up) for Linux GUI apps — beyond what Parallels or
  Fusion offer (no guest Vulkan there).
- No regression surface for existing users: VZ path untouched by default;
  GPU is per-distro opt-in.
- All new host dependencies are Apache-2.0/MIT/BSD; the license split
  (Apache repo / GPL kernel submodule) is preserved.
- The `VMBackend` seam positions msl for Option F (VZ custom virtio-gpu) as
  a drop-in third backend later — the guest stack (kernel config, Mesa,
  msl-way, protocol) is 100 % reusable across that switch.

Negative / accepted costs:
- Two VMs may run concurrently (memory footprint; mitigations in G7:
  lazy-boot both, idle-stop both, shared kernel/initramfs assets).
- GPU distros lose Rosetta (documented, enforced by config validation).
- We own a Mesa + virglrenderer + libkrun vendoring/patch treadmill until
  upstreams stabilize (mitigated by sha-pinning + G8 vendoring policy; the
  ecosystem is actively upstreaming — UTM→QEMU/virglrenderer, slp→libkrun).
- No audio, no snapshots, free-page-reporting-only ballooning on the GPU VM.

## Re-evaluation triggers

- macOS 27 GA ships `VZCustomVirtioDevice*` with workable shared-memory +
  queue semantics → start 16-future-work.md §F evaluation.
- virglrenderer MR !1583 / UTM QEMU series merge upstream → drop fork pins.
- libkrun 2.0 stabilizes (`krun_set_kernel`, display backends) → simplify G3.
- Apple ships Linux paravirt GPU (watch WWDC27) → reassess everything.
