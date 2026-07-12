# 16 — Future Work

Not gated; ordered by strategic value. Each item names its trigger.

## F1 — VZ reunification via `VZCustomVirtioDevice` (macOS 27+)

WWDC26 added `VZCustomVirtioDeviceConfiguration` +
`VZVirtioSharedMemoryRegionConfiguration` (macOS 27 beta): userspace custom
virtio devices with host↔guest shared memory inside Virtualization.framework.
If the queue + shared-memory-region semantics support virtio-gpu blob
mapping (the HOST3D map/unmap flow libkrun does via HVF today), msl can
implement **virtio-gpu as a VZ custom device**, reusing:
- the entire guest stack unchanged (kernel config, Mesa, msl-way, protocol),
- the entire host render stack (virglrenderer+MoltenVK/KosmicKrisp, surface
  export service — lifted from msl-vmm into a VZ-side device provider).

Result: one VM again, **Rosetta + GPU together**, krun backend retired or
kept as fallback. Trigger: macOS 27 GA + API validation spike (repeat G0.4
+ a queue-semantics probe). The G1 `VMBackend` seam and the G3 process
split were designed so this lands as a third backend with no guest churn.

## F2 — x86-64 on the GPU VM via FEX

FEX-Emu (+ binfmt_misc, muvm-style) gives Rosetta-less x86-64 in the GPU
VM. Slower than Rosetta but unlocks "GPU + x86-64" combos (Steam-class
workloads eventually). Needs: FEX aarch64 builds in gpu-tools, rootfs
overlay strategy, TSO considerations (kernel TSO patches — Asahi carries
them; evaluate for msl-kernel). Trigger: user demand after G9.

## F3 — Audio (virtio-snd)

libkrun's virtio-snd lacks a macOS backend today. Options: implement a
CoreAudio backend for libkrun's vhost-user-snd path (upstreamable), or an
msl-native audio plane over vsock (PipeWire module in guest → CoreAudio in
presenter — matches the msl-way pattern). Trigger: GUI apps needing sound
(most media apps); pairs naturally with a future clipboard/portal push
(the protocol ranges 25–36 are already reserved).

## F4 — SHM path upgrade via host-visible blobs

Sommelier's model: even software-rendered clients copy damage into a
**host-visible** intermediate buffer (virtio-gpu BLOB_MEM_HOST3D or
GET_IMAGE_REQUIREMENTS-style host-allocated), eliminating the vsock pixel
stream for VZ→krun-hosted SHM clients too. Turns today's
"copy → vsock → memcpy → IOSurface" into "copy → IOSurface". Trigger:
after G6.2, if SHM-app latency matters (large terminals, editors).

## F5 — ANGLE-in-guest for GLES

ChromeOS ships ANGLE-on-Venus for GLES apps. If Zink's GL coverage lags for
toolkit GLES paths, add ANGLE (GLES→Vulkan) libs to gpu-tools and route
`GDK_GL`/`QT_OPENGL=es` stacks through it. Trigger: G9 F6 failures rooted
in zink GLES.

## F6 — DRM native contexts

Not applicable on macOS hosts (requires a host DRM driver; Asahi native
context is for Linux hosts). Revisit only if msl ever targets Linux hosts.

## F7 — Vulkan ray tracing / advanced features passthrough

Venus passes RT extensions when the host ICD has them; MoltenVK/Metal RT
support is evolving. Track MoltenVK/KosmicKrisp releases; re-run
`vulkaninfo` feature audits at each host-dep bump.

## F8 — Render-server isolation

Enable virglrenderer's render-server (per-context worker processes) on
macOS when the fork supports it — crash isolation per GPU context instead
of per VM (closes R-6).

## F9 — Explicit-sync protocol completion

Full `linux-drm-syncobj-v1` server support in msl-way (if G5 shipped the
EXPORT_SYNC_FILE-only model) + host-side fence passing when the virtio-gpu
fence-passing RFC merges — removes guest-side waits from the latency path.

## F10 — Upstream give-back

Cocoa/IOSurface display backend for libkrun (`krun_display_backend`
vtable), virglrenderer IOSurface-export API, and the initrd/kernel-boot
patches — upstreaming shrinks our fork surface and is the cheapest
long-term maintenance strategy. Trigger: after G6 stabilizes.
