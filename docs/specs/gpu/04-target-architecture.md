# 04 — Target Architecture

## 1. Component overview

```
macOS host (per-user session)
┌─────────────────────────────────────────────────────────────────────────┐
│ msl daemon (msl daemon run — LaunchAgent, unchanged process)            │
│   DaemonCore ── VMBackend protocol ──┬── VZBackend (VMHost, as today)   │
│                                      └── KrunBackend (proxy object)     │
│        │ control socket (unix, JSON)        │ supervises                │
│        ▼                                    ▼                           │
│   msl-presenter (AppKit, per GUI runtime)  msl-vmm (child process)      │
│     CALayer/IOSurface presentation           libkrun (HVF) VM           │
│     ▲  IOSurface mach ports (G6)             virglrenderer + MoltenVK/  │
│     └────────────────────────────────────────  KosmicKrisp (venus)      │
│                                              vsock ports ⇄ unix sockets │
└─────────────────────────────────────────────────────────────────────────┘

Guest side (krun GPU VM)                     Guest side (VZ VM)
┌───────────────────────────────┐            ┌──────────────────────────┐
│ msl kernel (self-built,       │            │ msl kernel (self-built   │
│  CONFIG_DRM_VIRTIO_GPU=y)     │            │  or Kata-fetched)        │
│ msl-agent PID 1 (unchanged    │            │ msl-agent PID 1          │
│  + /dev/dri projection)       │            │ distros incl. Rosetta    │
│ distros (GPU-enabled)         │            │ msl-way (SHM path)       │
│ /run/msl/tools: msl-way,      │            └──────────────────────────┘
│  Mesa (venus ICD, zink, gbm)  │
│ msl-way (SHM + dmabuf paths)  │
└───────────────────────────────┘
```

Two utility VMs (at most) exist per user: the **VZ VM** (exactly today's) and
the **GPU VM** (krun backend). A distro is *placed* on exactly one backend by
configuration; both VMs share the same agent/initramfs/tools and the same
control protocol, so everything above the transport is backend-agnostic.

## 2. The VMBackend seam (G1)

```swift
public protocol VMBackend: AnyObject {
    var kind: VMBackendKind { get }                  // .vz | .krun
    var capabilities: VMBackendCapabilities { get }  // see below
    func startAndWait(onStop: @escaping (Error?, Bool) -> Void) throws
    func stopAndWait() throws
    func connectRaw(port: UInt32, timeout: TimeInterval) throws -> Int32
    func connectAndWait() throws -> VsockClient
    func setReverseListener(_ handler: ReverseVsockHandler, port: UInt32) throws
    func removeReverseListener(port: UInt32)
    func setMemoryTarget(mib: UInt64) throws         // balloon or FPR hint
    var consolePath: String { get }
}

public struct VMBackendCapabilities {
    public let rosetta: Bool          // VZ only
    public let gpu: Bool              // krun only (until Option F)
    public let balloon: BalloonKind   // .traditional | .freePageReporting | .none
    public let maxDisks: Int
    public let sharesByTag: Bool      // virtiofs tags supported
}
```

`BootSpec` grows optional krun-only fields (vRAM size, gpu flags, socket
directory) but stays a single validated value type. Every current
`VMHost`-constructing site takes a backend factory instead. The refactor is
mechanical; behavior with `.vz` must be bit-identical (G1 acceptance).

## 3. msl-vmm: the krun backend host process (G3)

Why a child process: `krun_start_enter()` never returns and terminates the
process on guest exit; the daemon must stay alive. Also isolates
virglrenderer/MoltenVK crashes away from the daemon (GPU stacks crash; the
blast radius must be one VM).

- New SwiftPM executable target `msl-vmm` (MSLCore dependency allowed;
  AppKit **not** linked — presentation stays in msl-presenter).
- Links `libkrun.dylib` (vendored, sha-pinned build), which links
  virglrenderer (slp fork tag until upstream), MoltenVK (and optionally
  KosmicKrisp as an alternative Vulkan ICD, selected via `VK_DRIVER_FILES`).
- Signed with `com.apple.security.hypervisor` (+ existing hardened-runtime
  release flags). The daemon/CLI keep only `com.apple.security.virtualization`.
- Process contract (daemon ⇄ msl-vmm):
  - Spawn: `posix_spawn` with `POSIX_SPAWN_SETSID | CLOEXEC_DEFAULT`
    (same pattern as `GuiPresenterLauncher.swift`), config passed as a
    single JSON document on inherited fd 3 (never argv — contains paths).
  - Readiness/status: msl-vmm writes line-delimited JSON events
    (`ready`, `stopped {code}`, `error {…}`) on inherited fd 4; the daemon's
    `KrunBackend` proxy translates these into the `VMBackend` callbacks.
  - Stop: SIGTERM → msl-vmm calls libkrun shutdown (or, in 1.x, sends
    ACPI-equivalent via agent control "shutdown" op first; SIGKILL after
    timeout). VM exit → process exit → daemon reaps.
- vsock mapping: libkrun exposes guest vsock ports as **unix sockets** in a
  per-VM runtime directory `~/.msl/run/gpuvm/` :
  - host→guest ports (5000,5001,5002,5003,5020,5030): msl-vmm registers
    `port → $RUN/vsock-<port>.sock`; `KrunBackend.connectRaw(port:)` is
    "connect to that unix socket, return the fd" — everything downstream
    (`VsockClient`, `ByteRelay`, presenter attach) is fd-based already and
    does not change.
  - guest→host ports (5010, 5040): msl-vmm listens on
    `$RUN/vsock-rev-<port>.sock` registered as the guest-connect target;
    accepted fds are relayed to the daemon over a `SCM_RIGHTS` channel on the
    control socket, feeding the existing `InteropListener`/
    `AuthBridgeListener` handler logic (which is delegate-shaped, not
    VZ-shaped, after G1).
- Networking: virtio-net backed by a userspace slirp-equivalent. Plan of
  record: embed **passt/gvproxy-style** relay as a vendored helper (gvproxy
  is Apache-2.0 and already the podman/krunkit pairing), unix-dgram socket to
  libkrun. Outbound-only parity with VZ NAT is sufficient (R5); the port
  forwarder stays vsock-based.
- Disks/shares/boot: same `BootSpec` inputs as VZ (distro images, `mac`
  share, staging share); kernel boot per G2 (§initramfs options).
- GPU: `krun_set_gpu_options2(VIRGLRENDERER_VENUS | VIRGLRENDERER_NO_VIRGL
  [| VIRGLRENDERER_RENDER_SERVER?], shm_size = vRAM window)`; vRAM default
  = min(8 GiB, hostRAM/4), configurable. Venus render worker isolation
  (render-server) is desirable but the slp fork builds with
  `-Drender-server=false`; revisit when upstream lands (15-risks R-6).

## 4. Guest stack (G2 + G4)

- **Kernel** (msl-kernel submodule `make build`): pinned kernel.org 6.12.x
  LTS; config = Kata/containerization-style minimal VM config **plus**:
  `CONFIG_DRM=y`, `CONFIG_DRM_VIRTIO_GPU=y`, `CONFIG_DRM_GEM_SHMEM_HELPER=y`,
  `CONFIG_VIRTIO_*` (already), `CONFIG_SYNC_FILE=y`, `CONFIG_UDMABUF=y`
  (cheap, useful), fbdev emulation **off** (no scanout console needed),
  16 KiB page experiment behind a config variant (see G2 §page-size).
  Produces `build/Image` (VZ profile) and `build/Image-gpu` (krun profile)
  if the profiles diverge; identical source, one submodule commit.
- **Mesa** (new `tools/mk-mesa.sh` or builder-VM build — G4 decides):
  pinned Mesa 25.x + the krunkit-required patches (16 KiB alignment et al.)
  built for aarch64-linux (glibc-in-distro is the ABI question G4 §linkage
  resolves; plan of record: **static-ish relocatable build against musl is
  NOT viable for Mesa — build against a pinned glibc sysroot in the builder
  VM** and set `MESA_LOADER_DRIVER_OVERRIDE`/ICD paths explicitly).
  Artifacts staged under initramfs `/tools/gpu/`:
  - `lib/libvulkan_virtio.so` + ICD json (Venus)
  - `lib/dri/zink_dri.so` / gallium `libgallium-*.so` (Zink GL, EGL/GLX glue)
  - `lib/libgbm.so`, `lib/libEGL*/libGL*` as needed (or rely on distro
    libglvnd — G4 §glvnd)
  - `share/vulkan/icd.d/msl-venus.aarch64.json`
- **Agent changes**: project `/dev/dri` render node into distro namespaces
  (device cgroup / bind of `/dev/dri` — G4); `gui_env()` gains a GPU branch:
  `VK_DRIVER_FILES=/run/msl/tools/gpu/share/vulkan/icd.d/msl-venus.aarch64.json`,
  `__EGL_VENDOR_LIBRARY_DIRS`/`LIBGL_DRIVERS_PATH=/run/msl/tools/gpu/lib/dri`,
  `MESA_LOADER_DRIVER_OVERRIDE=zink`, `GALLIUM_DRIVER=zink`, and **removal**
  of `LIBGL_ALWAYS_SOFTWARE=1` — mirrored in `GuiRuntime.env` + tests.
  Fallback branch (no `/dev/dri`, VZ VM) keeps today's llvmpipe env.

## 5. GUI data plane with GPU buffers (G5 + G6)

### Guest (msl-way)

- Advertise `zwp_linux_dmabuf_v1` (v4 with feedback: main device =
  `/dev/dri/renderD128`, format table from Venus/host caps) alongside
  `wl_shm`. Smithay's `DmabufState` provides the protocol; msl-way does not
  render — it only imports, tracks, and forwards.
- On commit with a dmabuf buffer:
  1. Resolve fd → virtio-gpu **resource id** (`drmPrimeFDToHandle` +
     `DRM_IOCTL_VIRTGPU_RESOURCE_INFO`) — the sommelier trick.
  2. Obtain an **explicit release/acquire pair**:
     - If the client uses `linux-drm-syncobj-v1`: use its acquire point.
     - Else: export the buffer's implicit reservation to a `sync_file` via
       `DMA_BUF_IOCTL_EXPORT_SYNC_FILE` (works for GL/zink clients whose
       submissions attach out-fences; venus WSI attaches them via
       FENCE_FD_OUT internally) and treat it as the acquire fence. Wait for
       it **in the guest** (poll on the sync_file fd inside calloop) before
       telling the host the buffer is ready. Guest-side waiting keeps the
       host protocol fence-free in v1 (simple, correct); a
     host-side-wait optimization is future work.
  3. Send `commit_gpu {win, seq, resource_id, w, h, format(drm fourcc),
     modifier, stride, scale_e12, serial, damage rects, t_*}` (new message
     type 40) instead of pixel payload. Buffer release back to the client
     happens on `present_ack` (existing pacing loop; one in flight).
- SHM clients keep the existing pixel path untouched. A GPU-capable
  msl-way falls back automatically per buffer type — mixed clients work.

### Host (msl-vmm ⇄ msl-presenter)

- msl-vmm owns virglrenderer state, therefore owns resource-id → renderer
  resource resolution. It runs a small **surface export service** on a unix
  socket in `$RUN`:
  - Stage 1 (G6.1, correctness): `export {resource_id}` → msl-vmm copies the
    resource contents (`virgl_renderer_transfer_read` / venus blob map) into
    a shared IOSurface pool and replies with an IOSurface mach port + seq.
  - Stage 2 (G6.2, zero-copy): guest scanout/client images are created
    IOSurface-backed at allocation time (VkImage in the venus renderer gets
    `VkExportMetalObjectCreateInfoEXT(IOSURFACE)` via virglrenderer patch /
    MR !1583-class hook); `export {resource_id}` just returns the mach port
    once; subsequent commits are pure "flip + fence" signals.
- msl-presenter changes: `commit_gpu` frames arrive on the same GuiChannel;
  the presenter asks msl-vmm (surface export service) for the IOSurface,
  then reuses the existing `GuiSurfacePool`/CALayer flip machinery. For
  stage 2 the pool holds imported IOSurfaces instead of locally-created ones.
- Ordering/sync host-side: guest already waited the acquire fence (v1
  model), so by the time `commit_gpu` is sent, the host texture is safe to
  sample. GPU work completion on the *host* GPU is serialized by Metal
  ordering within the msl-vmm queue before the IOSurface flip notification
  (stage-2 detail in G6; MoltenVK `MTLSharedEvent` export exists if needed).

### Presenter/daemon topology note

The GUI plane remains: msl-way (vsock 5020) → daemon ByteRelay →
msl-presenter. For the krun backend, "vsock 5020" is a unix socket from
msl-vmm; the daemon relay is unchanged. The *new* connection is
msl-presenter ⇄ msl-vmm (surface export service) — direct, not through the
daemon, carrying mach ports via `SCM_RIGHTS`-equivalent (mach port transfer
over a bootstrap-registered mach service or a `sendmsg` unix socket carrying
`IOSurfaceCreateXPCObject` payloads; G6 picks the mechanism).

## 6. Placement, lifecycle, memory (G7)

- Per-distro config gains `gpu: Bool` (default false). Validation:
  `gpu && rosetta` → error with explanatory message.
- Daemon holds up to two `VMBackend` instances keyed by kind; each keeps
  today's lazy-boot + idle-stop semantics independently. Distro state,
  sessions, forwarders, GUI runtimes are already per-distro tables — they
  gain a backend key.
- Memory: VZ VM keeps ladder+balloon. GPU VM: free-page reporting only →
  the ladder's reclaim step becomes "guest `mem_reclaim` op (agent drops
  caches; FPR returns pages)"; msl-vmm reports RSS to the daemon for
  `msl status`.
- `msl status` shows both VMs; `msl stop --all`/`shutdown` stop both.

## 7. Protocol compatibility rules

- GUI protocol stays **v5**. New capability handshake: `Hello` gains
  optional `caps: ["gpu-commit-v1", …]`; `HelloAck` echoes the accepted
  subset (pattern proven by `output_w/h`). `commit_gpu` (type 40) is only
  sent after the host acked `gpu-commit-v1`. Old host + new guest, new host
  + old guest, SHM-only distros: all keep working with zero changes.
- Agent control protocol (`Proto.version = 5`): new ops are additive JSON
  (`gpu_probe`, extended `gui_start` env) — same forward-compatible rules the
  agent already follows.

## 8. Failure/degradation ladder

1. GPU VM fails to boot / msl-vmm crashes → daemon marks krun backend down,
   distro start on that backend fails with actionable error; user can
   `msl config <d> --gpu off` to fall back. Daemon never auto-migrates a
   distro between backends (filesystems are backend-agnostic, but surprise
   migration violates least-astonishment; explicit config change + restart).
2. Venus init fails in-guest (missing caps) → agent `gpu_probe` reports it;
   `gui_env` falls back to llvmpipe; GUI still works via SHM.
3. Zink inadequate for an app → per-app env override documented
   (`MSL_GPU=off msl run …` sets the llvmpipe env), plus
   `msl config <d> --gpu-gl zink|llvmpipe` if needed (G7 decides surface).
4. Host ICD issues → `msl config --gpu-icd moltenvk|kosmickrisp` (hidden/dev
   flag initially).
