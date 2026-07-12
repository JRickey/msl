# 10 — Milestone G5: msl-way dmabuf + GUI Protocol Extension

Goal: msl-way accepts GPU client buffers (`zwp_linux_dmabuf_v1`), enforces
explicit synchronization, and forwards **references** (virtio-gpu resource
ids) to the host instead of pixels, negotiated per-connection so every
existing pairing keeps working. Host-side consumption of the references is
G6; G5 lands guest-side + protocol + a host stub that acks and discards
(behind a dev flag) so the guest work is testable independently.

## Entry criteria

- G4 (clients can actually produce dmabufs via Venus/Zink in the GPU VM).
- G0.3 findings (formats/modifiers observed; export-sync-file behavior).

## Protocol changes (guest `remote.rs` ⇄ host `GuiProto.swift`)

Version stays **5**. Capability negotiation via optional Hello fields
(pattern: `output_w/h` in `HelloAck`):

- `Hello` gains `caps: Vec<String>` (optional, absent = empty). Guest sends
  `["gpu-commit-1"]` when the GPU path is available (dmabuf global up).
- `HelloAck` gains `caps: Vec<String>` — the accepted subset. Host advertises
  `gpu-commit-1` only when a surface-export service is attached (G6; dev
  flag `MSL_GUI_GPU=1` before that).
- New message types (guest→host odd; keep clear of dormant 25–36):
  - `T_COMMIT_GPU = 41`, binary payload:
    ```
    u32 win, u32 seq, u32 w, u32 h,
    u32 drm_format(fourcc), u64 modifier,
    u32 n_planes, [u32 stride, u32 offset] × 4 (unused zeroed),
    u32 resource_id,            // virtio-gpu hw res id (RESOURCE_INFO)
    u32 scale_e12, u32 serial, u32 flags,
    u64 t_client_commit_ns, u64 t_send_ns,
    u32 n_rects, rects…         // damage, buffer coords (no pixel data)
    ```
  - `T_GPU_ERROR_G2H = 43` JSON `{win, seq, code, detail}` — guest-side
    import/sync failure telemetry (host may log + force SHM fallback for
    that window via existing configure path).
- Host→guest: `present_ack` (12) is reused verbatim — it is the release
  signal for the referenced buffer (see sync model). New
  `T_GPU_CAPS = 42` (host→guest, JSON, sent once after HelloAck when
  gpu-commit-1 accepted): `{formats: [{fourcc, modifiers: [u64]}…],
  max_planes: 1}` — drives the dmabuf feedback/format table msl-way
  advertises. v1 restricts to single-plane ARGB8888/XRGB8888/ABGR/XBGR with
  LINEAR + the modifiers G0.3 observed.
- Swift mirror: `GuiType` cases, `parseCommitGpu` with the same
  bounds-checking discipline as `parseCommit` (`GuiProto.swift:244-345`),
  unit tests mirroring `ProtoV3Tests`/existing Gui proto tests.

Compatibility matrix (must be tested): old-guest/new-host,
new-guest/old-host (caps absent → SHM only), SHM clients on GPU-capable
pairs (per-buffer fallback), version mismatch unchanged.

## msl-way changes (`guest/way/`)

### G5.1 — DRM device + dmabuf global
- New `gpu.rs` (linux-only cfg like `comp/input/xwm`): open
  `/dev/dri/renderD128` (iterate nodes, `drmGetVersion == virtio_gpu` — the
  sommelier scan), keep the fd; probe `RESOURCE_INFO` availability.
  Crate deps: `drm` + `drm-fourcc` (already transitive via Smithay) or raw
  ioctls via `nix` — prefer raw ioctl wrappers, msl-way avoids heavy deps.
- Advertise `zwp_linux_dmabuf_v1` via Smithay's `DmabufState` **only when**
  host acked `gpu-commit-1` and the device opened. Version: v4 with a
  single default feedback tranche (main device = render node, format table
  from `T_GPU_CAPS`). If Smithay 0.7's dmabuf v4 feedback support is
  insufficient, fall back to global v3 (formats+modifiers events) — v1
  acceptable; record which.
- Import handler: validate single-plane, known fourcc+modifier, then
  `drmPrimeFDToHandle` + `DRM_IOCTL_VIRTGPU_RESOURCE_INFO` → cache
  `(wl_buffer → {resource_id, w, h, fourcc, modifier, stride})`. Close GEM
  handle bookkeeping carefully (flink-free, handle refcounts per fd —
  dedupe imports by inode).

### G5.2 — Explicit sync (the correctness core)
Implicit fencing is unreliable under Venus (Mesa `vn_wsi.c`). Rule: **never
forward a buffer until its producer work is known complete.**
- Primary: `DMA_BUF_IOCTL_EXPORT_SYNC_FILE(READ)` on plane-0 fd at commit;
  register the returned sync_file fd with calloop; defer the
  `commit_gpu` send until readable (fence signaled). Coalesce per existing
  `Pacing` rules (a newer commit supersedes an unsent one → release the
  older buffer immediately with `wl_buffer.release`).
- If the client bound `linux-drm-syncobj-v1`: use the acquire point
  (translate to eventfd/sync_file via `SYNCOBJ_TIMELINE_WAIT` +
  `EXPORT_SYNC_FILE`) instead. Smithay support for the protocol is
  version-dependent — implement the server global by hand if absent
  (protocol is small; wlroots/kwin semantics documented). Optional for v1
  if EXPORT_SYNC_FILE proves sufficient with Venus clients in G0.3 —
  decide from spike data; record here.
- Release semantics: buffer held until `present_ack(seq)` (existing pacer
  guarantees ≤1 outstanding). On ack: signal release point (syncobj clients)
  or plain `wl_buffer.release` (host GPU consumption is already complete by
  present time in the G6 model — see 11-milestone-g6 §sync).
- Failure paths: EXPORT_SYNC_FILE unsupported/EINVAL → treat commit as
  immediately-ready (log once); import failure → `T_GPU_ERROR_G2H` + fall
  back to `read_full_buffer` **only if** the buffer is also mappable
  (dmabufs generally aren't CPU-readable here — instead send protocol error
  telemetry and let the client's next SHM/EGL fallback handle visuals; do
  not crash the window).

### G5.3 — Commit routing
`frames.rs on_commit`: buffer type dispatch — SHM → existing path
(unchanged); dmabuf → G5.1/G5.2 path producing `CommitGpuMeta` and encode
via new `encode_commit_gpu` (`remote.rs`). Damage handling identical
(surface→buffer transform, CSD crop rectangle math reused — the crop for
dmabuf commits is expressed as crop metadata `{x,y,w,h}` added to the
payload (host crops at composite time) since we cannot copy-crop pixels;
add `u32 crop_x, crop_y, crop_w, crop_h` to the T_COMMIT_GPU layout above).
Popups/X11 windows work identically (no special-casing — buffer origin is
per-surface).

### G5.4 — Host stub + tests
- Swift: parse + validate `T_COMMIT_GPU`, route to a `GuiGpuSink` protocol;
  dev-flag implementation logs and immediately acks (present_ack) so guest
  pacing runs. Real sink in G6.
- Rust unit tests: encode/decode round-trip, capability negotiation
  matrix, buffer-cache eviction, sync_file deferral state machine (mock
  fds via pipe). Swift tests: parser bounds/fuzz cases (mirror
  `parseCommit` tests), caps negotiation.

### G5.5 — Hardware validation (with G6.1 or the stub)
- `vkcube`/`vkmark` (Wayland WSI) in a GPU distro: commits flow as
  `T_COMMIT_GPU`, no black frames, pacing stable (stub: verify via logs +
  guest ledger; with G6.1: on-screen).
- Mixed clients: terminal (SHM) + vkcube (dmabuf) in one runtime.
- Xwayland GL client (`glxgears` via zink) → dmabuf path through xwm.

## Exit criteria

- Protocol negotiated + fully backward compatible (matrix tested).
- msl-way forwards fence-complete resource references with damage + crop;
  SHM path byte-identical when caps absent.
- All unit suites green (`cargo test --workspace`, `swift test`);
  clippy/fmt/lint clean.
- Sync model decision (EXPORT_SYNC_FILE vs +syncobj protocol) recorded here
  with spike evidence.
