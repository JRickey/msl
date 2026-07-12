# 02 — Research Findings (verified July 2026)

Research method: parallel primary-source investigation (Apple docs/data JSON,
kernel UAPI headers, Mesa/virglrenderer/libkrun/krunkit/QEMU/UTM sources,
vendor KBs, maintainer statements). Each claim below carries its strongest
source. Egress note: some canonical hosts (gitlab.freedesktop.org,
docs.mesa3d.org, qemu.org, lists) were proxy-blocked during research; those
claims were verified via byte-identical GitHub mirrors or search excerpts of
the exact page and are marked ◐ where only excerpt-verified. Re-verify ◐ items
opportunistically during implementation.

## 1. Claim verified: Virtualization.framework has no Linux GPU acceleration

- `VZVirtioGraphicsDeviceConfiguration` (macOS 13+) is **2D scanout only** —
  its entire API is `scanouts: [VZVirtioGraphicsScanoutConfiguration]`
  (width/height). No virgl, no Venus, no contexts, no blob resources.
  Source: Apple doc data JSON for the class; WWDC22 session 10002 states the
  model outright: "Linux renders the content, gives the rendered frame to
  Virtualization framework, which can then display it."
- Nothing changed in macOS 14, 15 (additions: XHCI, nested virt), 26
  (additions: `VZVmnetNetworkDeviceAttachment`), or the **macOS 27 "Golden
  Gate" beta** (WWDC26 session 224: macOS-guest provisioning, USB passthrough,
  DiskImageKit, custom virtio devices — no Linux GPU).
- `ParavirtualizedGraphics.framework` (Metal for guests) requires a guest
  driver that only macOS ships. No Linux driver exists; framework unchanged
  in the macOS 27 cycle.
- Ecosystem confirmation: UTM maintainer: "There is no GPU acceleration under
  AVF" (utmapp/UTM discussion #5482); UTM issue #5602 (closed not-planned)
  shows llvmpipe under a VZ virtio-gpu; Lima `vz` and vfkit expose only
  width/height virtio-gpu; Tart claims paravirt GPU only for macOS guests.

**New and strategically important:** macOS 27 beta adds
`VZCustomVirtioDeviceConfiguration` (userspace custom virtio devices) and
`VZVirtioSharedMemoryRegionConfiguration` (host↔guest shared memory) —
WWDC26 session 224. These are the exact primitives needed to implement a
virtio-gpu device **inside** VZ (keeping Rosetta) in the future. Beta,
unproven, macOS 27-only → treated as future work (16-future-work.md), not the
plan of record.

## 2. Claim verified: Apple's `container`/`containerization` have no GPU

- apple/containerization issue #46 "GPU access from containers on Apple
  Silicon" — closed **wontfix** by Apple. Discussion apple/container#62:
  maintainer egernst: "we do not currently support this." Issue #480
  (paravirt graphics via virtio-gpu, Jan 2026) open, unanswered; community
  PR #569 unreviewed.
- Their kernel config (`containerization/kernel/config-arm64`) has
  `CONFIG_DRM=y` but **`# CONFIG_DRM_VIRTIO_GPU is not set`** — even the
  device driver is absent. Their default kernel is the Kata static kernel
  (same recipe msl's `kernel/` submodule copies).
- WWDC26's `container` 1.0 ("container machines", session 389) still has no
  GPU mention. Apple GPUs have no IOMMU-based PCI passthrough, so
  "passthrough" in the PCI sense is off the table permanently; only
  paravirtualization can work.

## 3. Feasibility proof: commercial hypervisors do Linux 3D on Apple Silicon

Both build their own device models on **Hypervisor.framework** (not VZ):

- **Parallels Desktop** (since 17.1, 2021): standard **virtio-gpu + VirGL**
  rendered via Metal; on by default for Linux; works without Parallels Tools.
  Ceiling: OpenGL 4.1 compat profile (macOS's own GL ceiling). **No Vulkan**
  for guests through PD 26 (2025). Sources: KB 128518, KB 122807, PD 26 docs.
- **VMware Fusion** (since 13, 2022): proprietary SVGA3D paravirt device +
  upstream `vmwgfx`/Mesa svga guest stack → **OpenGL 4.3** for arm64 Linux
  guests (needs guest kernel 5.19+, Mesa 22.1.1+; Broadcom KB 315602). **No
  Vulkan** for guests. Free for all use since Nov 2024.

Conclusion: Linux guest 3D on Apple Silicon is a solved problem *given a
custom VMM*; Venus would exceed both commercial products by delivering
Vulkan 1.2–1.4 class guests.

## 4. The only shipping open path: libkrun (HVF) + virtio-gpu Venus

- **libkrun** (github.com/libkrun/libkrun, Apache-2.0): Rust VMM library;
  KVM on Linux, **Hypervisor.framework on macOS/arm64** (macOS 14+). Devices:
  virtio-console/blk/fs/net/vsock/rng/balloon(free-page-reporting-only)/
  **gpu (venus + native-context)**. GPU via vendored rutabaga_gfx +
  virglrenderer; enabled with `krun_set_gpu_options2(ctx, virgl_flags,
  shm_size)` where `shm_size` sizes the virtio shared-memory "vRAM" window.
- **The macOS enabler** is libkrun PR #174 (merged 2024-02-21, author Sergio
  López): a `get_map_ptr()` extension to virglrenderer returns a host pointer
  to the MoltenVK-backed allocation, and libkrun injects that mapping into
  guest-physical space via HVF (`WorkerMessage::GpuAddMapping`,
  `src/vmm/src/worker.rs`) — replacing dmabuf-fd passing, which macOS cannot
  do. Plus `RESOURCE_UUID` support. Host render chain: guest Mesa Venus →
  virtio-gpu → virglrenderer venus decoder → **MoltenVK → Metal**.
- **Host virglrenderer is a fork today**: `gitlab.freedesktop.org/slp/
  virglrenderer` tag `0.10.4e-krunkit`, built `-Dvenus=true
  -Drender-server=false`, deps molten-vk + libepoxy (slp/homebrew-krun
  formula). Upstreaming in progress (virglrenderer MR !1583 ◐ "venus on
  macOS", returns an MTLTexture usable for scanout; MR !1458 OPAQUE_FD).
- **Guest Mesa must currently be patched** (slp's `mesa-libkrun-vulkan` COPR;
  Lima's krunkit guide scripts a downgrade+versionlock). Red Hat: removing
  that requirement "requires changes in the Linux kernel" ◐. UTM's parallel
  guest-Mesa patches: 16 KiB page-alignment workaround (Apple host pages are
  16 KiB) + a Mesa 25 regression revert (osy's build gist). → msl ships its
  own pinned/patched Mesa (G4), which neutralizes this as a user-facing
  problem.
- **krunkit** (vfkit-CLI-compatible wrapper, libkrun-efi): powers
  `podman machine` — **libkrun is the default podman provider on macOS as of
  Podman 6.0**; Lima 2.0 has an experimental krunkit vmtype whose "standout
  feature is GPU support via Mesa's Venus driver". RamaLama uses it for GPU
  inference. Production-grade for compute.
- **Performance**: llama.cpp Vulkan-in-VM reached **75–80 % of native Metal**
  (Red Hat, Sept 2025; llama.cpp discussion #12985: pp512 428 vs 746 t/s on
  M2 Max earlier in 2025); Red Hat's llama.cpp "API remoting" prototype on the
  same virtio-gpu transport is near-native — the transport is not the
  bottleneck. Boot: libkrun microVMs start in ~0.1–0.4 s (muvm/asahi;
  microsandbox claims <100 ms).
- **Display**: libkrun ≥1.19/2.0 has a pluggable display backend API
  (`krun_add_display` up to 16 scanouts + EDID/DPI;
  `krun_display_backend` vtable `configure_scanout/alloc_frame/present_frame`;
  `include/libkrun_display.h`) and an input-injection API. Current feature
  level is `KRUN_DISPLAY_FEATURE_BASIC_FRAMEBUFFER` — scanout presentation is
  a CPU `transfer_read` into an embedder buffer (verified in
  `virtio_gpu.rs`), i.e. **not yet zero-copy**; a GTK example exists; no
  Cocoa backend. msl's G5 design bypasses scanout for app windows (buffers
  travel as resource references in msl-way's protocol), so this limitation
  costs us nothing on the main path.
- **Sharp edges** (drive the G3 design):
  - `krun_start_enter()` **never returns and the VMM owns the process**
    (calls `exit()` on guest shutdown) → one VM per child process, hard
    requirement.
  - **No Rosetta, ever** (see §5). No audio backend on macOS. Balloon =
    free-page reporting only. No vCPU hotplug, no snapshots. krunkit caps
    guest RAM at 60 GiB (62 GiB RAM+vRAM budget).
  - Boot models: 1.x macOS = bundled-kernel (libkrunfw, GPL) or EFI
    (`krun_set_firmware`, EDK2 `KRUN_EFI.silent.fd`); **2.0 adds
    `krun_set_kernel`** (raw/ELF/Image.gz direct kernel boot). 2.0 is a
    breaking rewrite in progress — pin and patch 1.x, or vendor a 2.0
    snapshot; decision in G3.
  - virtio-fs semantics stricter than VZ's (podman discussion #27679 —
    permission friction; `permissionSemantics=` knob exists in krunkit).
  - libkrun security stance: "think about the guest and the VMM as a single
    entity" — same trust model msl already has (per-user daemon, user data).

## 5. Rosetta is locked to Virtualization.framework — no workaround we can ship

- The host binary (`/Library/Apple/usr/libexec/oah/RosettaLinux/rosetta`)
  performs an **undocumented ioctl challenge/response against the virtiofs
  device** (codes 0x80456122/0x80456125/0x80806123/0x6124) that only VZ's
  host side answers; outside VZ it aborts: "Rosetta is only intended to run…
  using Virtualization.framework with Rosetta mode enabled"
  (tnk4on.github.io/libkrun-rosetta, reproduced in libkrun).
- libkrun **removed** its Rosetta support deliberately (commit
  `0b6a7356…` "macos: drop Rosetta support"); Docker's custom VMM ships
  without Rosetta "due to a limitation imposed by Apple"; every ecosystem
  tool (Docker/Lima/Colima/UTM/podman) offers Rosetta only on VZ backends.
- Existing bypasses NOP-patch Apple's binary (rosetta-spice,
  rosetta-linux-asahi) — SLA/DMCA §1201 territory; **not shippable**.
- Consequence: **Rosetta and GPU are per-distro mutually exclusive**; Rosetta
  distros stay on the VZ VM (G7 placement policy). x86-64-on-GPU-VM via FEX
  is future work.

## 6. QEMU/HVF eliminated as a backend

- **No vsock on macOS hosts**: vhost-vsock is Linux-kernel-only; QEMU has no
  userspace virtio-vsock (open RFE, gitlab qemu#2095); the rust-vmm
  vhost-user-vsock daemon still doesn't run on macOS (GSoC 2025 final report).
  msl's entire control surface is vsock → disqualifying by itself.
- **No virtiofs on macOS hosts** (virtiofsd is Linux-only; 9p is the only
  option, with known msize/perf limits). vmnet needs root or the restricted
  `com.apple.vm.networking` entitlement. No savevm/loadvm under HVF.
- Upstream QEMU also cannot do GL/venus on Darwin (epoxy hard-requires EGL;
  Cocoa UI has no GL path). Everything that works (UTM v5's Venus+MoltenVK,
  Vulkan 1.3 guests) lives in UTM's forks; upstreaming is in flight
  (qemu-devel RFC "virtio-gpu-virgl: introduce Venus support for macOS",
  Dec 2025 ◐; virglrenderer MR !1583 ◐). QEMU remains valuable **as the
  upstream source of the macOS venus/virglrenderer patches**, not as a VMM.
- GPL is manageable (subprocess-exec pattern; msl is Apache-2.0) but moot
  given the technical gaps.

## 7. Guest stack facts that shape the design

### virtio-gpu (kernel UAPI, spec-normative)

- Capsets: VIRGL=1, VIRGL2=2, GFXSTREAM_VULKAN=3, **VENUS=4**,
  **CROSS_DOMAIN=5**, DRM=6 (`include/uapi/linux/virtio_gpu.h`).
- Context create: `DRM_IOCTL_VIRTGPU_CONTEXT_INIT` params CAPSET_ID /
  NUM_RINGS / POLL_RINGS_MASK; submissions via `DRM_VIRTGPU_EXECBUFFER`
  (flags `FENCE_FD_IN|FENCE_FD_OUT|RING_IDX`) → `CMD_SUBMIT_3D`.
- Blob resources: `RESOURCE_CREATE_BLOB` with `BLOB_MEM_GUEST|HOST3D|
  HOST3D_GUEST`, flags `MAPPABLE|SHAREABLE|CROSS_DEVICE`; HOST3D maps into
  the guest through the device shared-memory window (`MAP_BLOB`).
  `CROSS_DEVICE` requires `F_RESOURCE_UUID`/`RESOURCE_ASSIGN_UUID`.
- Fences: per-(context, ring) ordered timelines; guest-visible as
  `sync_file` out-fences; **drm syncobj + timeline support in the virtio-gpu
  driver since Linux 6.6** (`DRIVER_SYNCOBJ | DRIVER_SYNCOBJ_TIMELINE`).
  Host→guest fence *passing* (host-side waits) is an unmerged RFC.
- Guest kernel needs ≥5.16-era features: `3D_FEATURES`, `CAPSET_QUERY_FIX`,
  `RESOURCE_BLOB`, `HOST_VISIBLE`, `CONTEXT_INIT` (Mesa venus docs; krunkit
  issue #50). Kernel 6.12 LTS (already msl's line) satisfies all incl.
  syncobj.

### Venus (Mesa)

- Vulkan 1.3 exposed since Mesa 23.1; **1.4 since Mesa 25.1** (+ ray-tracing
  extension pass-through). Practical guest floor for this program:
  **Mesa ≥ 25.x pinned by us** (G4). Stable-tagged in virglrenderer since
  May 2023; ChromeOS ships it (Borealis/ARCVM); QEMU 9.2+ ships it (Linux
  hosts).
- Host driver requirements (venus.rst): VK 1.1 + `VK_KHR_external_memory_fd`
  (Linux profile) or the Android profile (`dma_buf` + `image_drm_format_
  modifier` + `queue_family_foreign`). **MoltenVK provides neither fd flavor**
  — it has `VK_EXT_external_memory_metal` (1.3.0+) and `VK_EXT_metal_objects`
  instead; this is exactly what the slp/UTM virglrenderer patches bridge
  (host pointer / MTLTexture instead of fd).
- **Implicit fencing is broken under venus by design** — Mesa `vn_wsi.c`:
  "venus requires explicit fencing (and renderer-side synchronization) to
  work well." → msl-way must consume explicit fences (G5 sync model).
  Venus still `SIMULATE_SYNCOBJ` in userspace over `FENCE_FD_OUT` sync_files
  — sync_file out-fences are therefore the reliable guest primitive.
- MoltenVK gaps that pass through to guests: no geometry shaders (UTM patched
  their MoltenVK), no transform feedback, no pipeline-statistics queries;
  portability-subset semantics.

### OpenGL strategy (Zink / ANGLE)

- Zink is production-grade upstream (GL 4.6 conformant via PowerVR + NVK;
  default GL driver for NVIDIA Turing+ since Mesa 25.1; ~93 % of radeonsi).
- **Zink requirements vs MoltenVK**: baseline needs
  `VK_EXT_custom_border_color`, `VK_EXT_provoking_vertex`,
  `VK_EXT_border_color_swizzle` (MoltenVK: missing or private-API-only);
  GL 3.0 needs `VK_EXT_transform_feedback` + `VK_EXT_conditional_rendering`
  (MoltenVK: missing); GL 3.2 needs geometry shaders (MoltenVK: none).
  → **Zink over MoltenVK ≈ experimental GL 2.1.** Mesa docs: "Zink on macOS
  is experimental with very limited capabilities."
- **KosmicKrisp** (LunarG, merged Mesa 26.0, Vulkan 1.3 CTS-conformant on
  Apple Silicon, macOS 26/Metal 4) was built explicitly so Zink can provide
  GL on macOS; Minecraft over zink→KosmicKrisp has been demonstrated ◐. Per
  UTM (Jan 2026) it is "not at feature parity with MoltenVK, no DXVK". →
  **host ICD is a configuration axis**: MoltenVK = stability/Vulkan-app
  default; KosmicKrisp = GL-capable option. G0 measures both.
- ChromeOS's answer for GLES is **ANGLE-on-Venus** (ARCVM); optional for msl
  as a GLES fallback for toolkits (16-future-work.md).
- llvmpipe/lavapipe remain the universal fallback (status quo).

### Wayland forwarding prior art (crostini/sommelier, cross-domain)

- The CROSS_DOMAIN context type tunnels the Wayland protocol + fd translation
  to a **host Wayland compositor**. macOS has none, so msl keeps its own
  guest compositor + custom host presenter. What we import from this design:
  1. **fd→resource-id translation**: guest side resolves a client dmabuf to
     its virtio-gpu resource id via `drmPrimeFDToHandle` +
     `DRM_IOCTL_VIRTGPU_RESOURCE_INFO` (sommelier `virtgpu_channel.cc`).
     msl-way does the same and sends the id in its own protocol (G5).
  2. **Allocate-on-host, import-into-guest** (GET_IMAGE_REQUIREMENTS →
     HOST3D blob) as the zero-copy buffer pattern.
  3. Poll/fence wakeup via ring + DRM fd readability.
- Sommelier also proves the "one guest CPU copy of damage into a
  host-visible intermediate buffer" model for wl_shm clients — msl's SHM path
  can later adopt host-visible blobs to shed one copy (16-future-work.md).
- The venus/vtest transport requires SCM_RIGHTS + same-kernel mmap; **it
  cannot run over vsock** — a "keep VZ and tunnel the GPU protocol" design is
  structurally impossible, not merely slow. (This kills Option B in
  03-decision.md.)

### Host presentation (macOS)

- `VK_EXT_metal_objects` (MoltenVK ≥1.1.11): create a VkImage with
  `VkExportMetalObjectCreateInfoEXT(IOSURFACE)` → MoltenVK auto-backs it with
  an IOSurface (`MVKImage.mm useIOSurface`) → `vkExportMetalObjectsEXT`
  returns the `IOSurfaceRef`.
- IOSurface is the kernel-shareable currency:
  `IOSurfaceCreateMachPort`/`IOSurfaceLookupFromMachPort` (or XPC objects);
  `CALayer.contents = IOSurface` is already msl's presentation primitive
  (`GuiSurface.swift`), and UTM ships the same shape (renderer → IOSurface →
  helper-process → Metal blit).
- virglrenderer hooks: `virgl_renderer_resource_get_info`, blob export, the
  libkrun `get_map_ptr()` extension, and (in-review) MTLTexture-for-scanout
  handles (MR !1583 ◐ / UTM QEMU series).

## 8. Bottom-line matrix

| Option | vsock | virtiofs | Rosetta | GPU (Venus) | License | Verdict |
|---|---|---|---|---|---|---|
| VZ (status quo) | ✅ | ✅ | ✅ | ❌ (2D scanout only) | n/a | keep for Rosetta + default |
| VZ + GPU-over-vsock tunnel | ✅ | ✅ | ✅ | ❌ structurally impossible (no fd passing/shared mem) | — | rejected |
| QEMU/HVF | ❌ none | ❌ 9p only | ❌ | ◐ fork-only | GPLv2 | rejected |
| **libkrun (krun backend)** | ✅ (unix-socket bridged) | ✅ | ❌ | ✅ shipping | Apache-2.0 | **selected** |
| Custom VMM on HVF from scratch | build it | build it | ❌ | build it | ours | rejected (months of device work libkrun already did) |
| VZ + `VZCustomVirtioDevice` virtio-gpu | ✅ | ✅ | ✅ | build it (macOS 27 beta API) | n/a | future work |
