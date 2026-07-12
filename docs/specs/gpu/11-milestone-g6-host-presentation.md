# 11 — Milestone G6: Host Presentation (copy path, then zero-copy)

Goal: turn `T_COMMIT_GPU` resource references into pixels in the existing
CALayer pipeline. Stage 1 (G6.1) is a correctness-first copy inside msl-vmm;
stage 2 (G6.2) is IOSurface-backed zero-copy. The presenter keeps its
process boundary and pacing model throughout.

## Entry criteria

- G3 (msl-vmm owns virglrenderer state), G5 (references arrive at host).
- G0.4 (IOSurface export recipe validated).

## Component: surface-export service in msl-vmm

msl-vmm hosts virglrenderer, so only msl-vmm can resolve
`resource_id → renderer resource`. Add a unix-socket service
(`$RUN/gpu-export.sock`), one connection per presenter, message protocol
(length-prefixed JSON + OOB rights):

```
→ {op:"open", win, resource_id, w, h, fourcc, modifier}
← {ok, surface: <IOSurface via mach/XPC>, export_id}
→ {op:"flush", export_id, seq, damage:[…]}      // make contents current
← {ok, seq}                                      // host GPU work complete
→ {op:"close", export_id}
```

Rights transfer mechanism: `IOSurfaceCreateXPCObject` payloads over an
`xpc_connection` (preferred: anonymous listener endpoint handed to the
presenter through the daemon during gui_attach), or mach-port send rights
over `sendmsg` — implementer picks the first that proves reliable; wrap it
behind `SurfaceRights` helper so the choice is swappable. The presenter
side never talks to libkrun/virglrenderer directly.

Threading: the export service runs on msl-vmm's own serial queue and calls
into virglrenderer only on the thread(s) libkrun designates for the GPU
worker — coordinate via the same worker-message channel libkrun uses
internally (`WorkerMessage`); this likely requires a small libkrun patch to
expose a "run closure on GPU thread" hook or an exported C callback —
budget it (vendored tree, patch under `third_party/libkrun/patches/`).

## G6.1 — Copy path (correctness milestone)

- `flush` implementation: locate resource → read back pixels →
  `IOSurfaceLock` + copy damage rects → unlock. Readback options in
  preference order: (1) venus blob map via the existing `get_map_ptr`
  mechanism when the resource is host-visible (most WSI swapchain images
  under venus-on-MoltenVK are — verify); (2) `virgl_renderer_transfer_read`
  staging; (3) vkCmdCopyImageToBuffer via a service-owned VkDevice sharing
  the renderer's instance (last resort).
- Presenter: `GuiGpuSink` real implementation — on `T_COMMIT_GPU`:
  ensure `open`ed export for (win,resource_id) (cache; resources recycle in
  swapchains so expect 2–4 opens per window), `flush(seq, damage)`, then
  hand the IOSurface into the existing present machinery. Reuse
  `GuiSurfacePool` shape: the pool's "apply damage then flip" becomes
  "flush then flip" — the copy already happened in msl-vmm, so the
  presenter skips `GuiSurface.apply` and flips the imported surface
  directly (small refactor of `GuiWindow.presentFrame` to accept
  an externally-updated IOSurface; keep triple-buffer semantics by
  round-robining export surfaces per swapchain image — natural fit since
  each swapchain image is its own resource_id/IOSurface).
- Crop (CSD) from the commit's crop metadata: set the layer's
  `contentsRect` (normalized crop) instead of pixel-cropping — no copy.
  Verify popups + resize verdict logic (`applySizeVerdict`) with
  contentsRect in play; `GuiSizing` math unchanged (logical size from
  crop_w/h / scale_e12).
- present_ack timing: ack after CALayer flip commit, as today
  (`recordAndAck`). Ledger: new `path` column (shm|gpu-copy|gpu-zero) in
  the CSV for A/B analysis.

Acceptance G6.1: vkcube/vkmark/glmark2 windows render correctly on screen
(colors, damage, resize, popups, cursor), sustained 10-min soak without
leak (IOSurface count stable via `leaks`/Instruments), ledger p95 recorded.

## G6.2 — Zero-copy path

Make the venus renderer allocate **IOSurface-backed** images for exportable
resources so `flush` becomes a no-op fence:

- virglrenderer/venus patch (tracked against MR !1583 upstream direction):
  for resources whose guest side sets BLOB/SHAREABLE (or scanout-intent
  bind), chain `VkExportMetalObjectCreateInfoEXT{IOSURFACE}` into the
  renderer's VkImage creation; expose
  `virgl_renderer_resource_get_iosurface(res_id) → IOSurfaceRef` (new API in
  our vendored fork; upstream proposal alongside). MoltenVK auto-creates
  the IOSurface (`MVKImage::useIOSurface`) — the image *is* the shareable
  surface from birth.
- `open` returns that IOSurface once; `flush(seq)` waits host GPU work:
  export the resource's last-write completion — v1: `vkQueueWaitIdle` on the
  venus context queue is too blunt; use venus fence tracking — the guest
  already waited the *client's* fence (G5), and venus renderer executes
  submissions in order, so by commit time the renderer-side writes are
  queued; completion needs a per-resource `MTLSharedEvent` or
  `vkExportMetalSharedEventEXT` signaled after the last blit — implement
  as: renderer signals export_id's event at `write_context_fence` for the
  ring that carried the final barrier. Pragmatic v1: `flush` performs a
  small `vkWaitForFences` on the last fence observed for that context ring
  (the plumbing exists — vkr's per-queue sync threads retire ring fences).
  Measure; refine only if it shows in the ledger.
- Presenter unchanged from G6.1 apart from skipping per-frame flush copies
  (flip + contentsRect only). CATransaction discipline as today
  (`commitLayer`).
- Fallback: if IOSurface backing fails for a format/usage, service falls
  back to G6.1 copy for that export (per-export flag in `open` reply);
  presenter is agnostic.

Acceptance G6.2: same functional suite as G6.1; ledger shows p95
commit→present for 2560×1440 vkcube ≤ 50 % of G6.1 copy path or ≤ SHM
baseline (whichever is stricter); CPU% of msl-vmm during fullscreen vkmark
drops materially vs G6.1 (record).

## Multi-window / multi-runtime notes

- One export service connection per presenter (per GUI runtime); export_ids
  scoped to connection; msl-vmm cleans up on disconnect (presenter crash =
  runtime teardown, daemon's 60 s grace reconnect logic in
  `DaemonCore+GUI.swift` reattaches and re-opens).
- Resource lifetime: guest may destroy a wl_buffer while exported —
  msl-way sends nothing (buffer cache handles), but the renderer resource
  can be unreffed by the guest; msl-vmm must hold a renderer-level ref per
  export (virgl resource ref API) until `close`.

## Exit criteria

- G6.1 then G6.2 acceptance met on hardware; SHM path regression-free.
- Vendored virglrenderer patch minimal + documented + upstream-proposed.
- Ledger CSV distinguishes paths; numbers recorded in 14-validation.
