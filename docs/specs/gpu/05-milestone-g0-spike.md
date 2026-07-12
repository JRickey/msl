# 05 — Milestone G0: De-risking Spike

Goal: validate every load-bearing external assumption **with zero msl code
changes**, using stock krunkit + a stock guest, on real Apple Silicon
hardware. Output is a written report (`docs/reports/gpu-g0-spike.md`, local)
and go/no-go updates to 15-risks-and-contingencies.md.

**This milestone requires a macOS 26+ Apple Silicon machine with Homebrew.**
It cannot run in CI or in a Linux sandbox. Estimated effort: 2–4 sessions.

## Entry criteria

None (first milestone).

## Environment setup

```sh
brew tap slp/krun
brew install krunkit          # pulls libkrun, virglrenderer (venus fork),
                              # molten-vk, libepoxy, gvproxy
# Guest: Fedora 42+ aarch64 raw/qcow2 cloud image, or the prebuilt
# quay.io/slopezpa/fedora-vgpu-llama container via podman machine.
# Easiest harness: podman machine with provider=libkrun, or krunkit directly
# with an EFI-bootable Fedora disk image.
```

Alternative harness (closer to msl's future shape): Lima ≥ 2.0 `krunkit`
vmtype — it scripts the patched-Mesa guest setup (slp/mesa-libkrun-vulkan
COPR + versionlock) automatically. Use whichever gets to a running guest
fastest; record which was used.

## Work items

### G0.1 — Venus *rendering* (not just compute) works

The single most important unknown: public krunkit usage is compute-heavy and
one report claims "vulkan compute shaders only, not rendering/draw". Refute
or confirm.

Steps:
1. In the guest (patched Mesa installed): `vulkaninfo` → record device name
   ("Virtio-GPU Venus (Apple …)"), Vulkan version, extension list. Save
   full output.
2. Headless render test: `vkmark --headless` or a small offscreen vkcube
   variant (no display server needed): confirm draws execute and readback
   images are correct (non-black, correct triangle).
3. With a display: run Weston or Sway **inside the guest** on
   `WLR_BACKENDS=headless` / weston headless with the Venus Vulkan renderer
   or GL-on-zink; then `vkcube --wsi wayland` under it. We do not care about
   seeing the image on the mac (no display path in krunkit); we care that WSI
   swapchains, fencing, and present loops run without hangs or validation
   errors. Capture `VK_LAYER_KHRONOS_validation` output for a 60 s run.
4. Record dmesg + virglrenderer stderr for anomalies.

Accept: sustained vkcube/vkmark WSI loop ≥ 5 min, no hang, no validation
storm, plausible fps. **If this fails → program halt; escalate to
15-risks R-1 contingency (co-develop fixes with libkrun upstream or defer).**

### G0.2 — Zink GL levels under MoltenVK vs KosmicKrisp

1. `glxinfo -B` / `eglinfo` with `MESA_LOADER_DRIVER_OVERRIDE=zink
   GALLIUM_DRIVER=zink` in the guest, host ICD = MoltenVK (default). Record
   GL version + renderer string. Expectation from research: GL 2.1.
2. Swap host ICD to KosmicKrisp: on the host, build/obtain Mesa's
   KosmicKrisp ICD (`brew install startergo/virglrenderer` tap variants or a
   local Mesa build with `-Dvulkan-drivers=kosmickrisp`), point krunkit's
   environment at it via `VK_DRIVER_FILES=<kk icd json>` before launch.
   Re-run: record GL version. Expectation: ≥ 3.3, target 4.x.
3. glmark2 (wayland) under both ICDs; also under llvmpipe for baseline.
   Record scores.
4. Toolkit smoke: GTK4 demo (`gtk4-demo`) and a Qt6 Quick app with GL
   enabled — do they pick zink EGL and render correctly?

Accept: zink initializes on at least one host ICD with ≥ GL 2.1 and no
crashes; glmark2 ≥ 3× llvmpipe baseline on that ICD. Record which ICD is the
recommended default for G4/G6. **If KosmicKrisp fails entirely and MoltenVK
caps at 2.1, GL story ships as "GLES/GL2.1 + Vulkan first-class" — not a
halt, but update 00-scope G-2 language.**

### G0.3 — dmabuf export/import inside the guest

msl-way's whole GPU path depends on: client renders with Venus/Zink →
exports dmabuf → another process (compositor) imports it and resolves the
virtio-gpu resource id.

1. In the guest, run a Wayland compositor that requires dmabuf
   (`sway`/`weston` with GL renderer on zink) and a Venus Vulkan client under
   it. Confirm `zwp_linux_dmabuf_v1` negotiation succeeds (WAYLAND_DEBUG=1)
   and frames present.
2. Write/adapt a ~100-line C probe: allocate a GBM BO (or VkImage with
   dmabuf export) → `drmPrimeHandleToFD` → in a second process, import via
   `drmPrimeFDToHandle` + `DRM_IOCTL_VIRTGPU_RESOURCE_INFO` → print
   resource id + stride. This is exactly msl-way's G5 step. Verify ids are
   stable and non-zero.
3. Verify `DMA_BUF_IOCTL_EXPORT_SYNC_FILE` works on these BOs (kernel ≥6.0
   in guest) and that waiting the sync_file completes after client submits.

Accept: probe prints valid resource info; sync_file waits behave. Record
format/modifier list observed (drives G5 format negotiation).
**Failure → the commit_gpu design needs the host-allocated-buffer variant
(GET_IMAGE_REQUIREMENTS pattern) — G5 contingency, not halt.**

### G0.4 — Host-side IOSurface export recipe

On the host (no VM needed): a ~200-line Swift/ObjC + MoltenVK probe:
1. Create VkImage with `VkExportMetalObjectCreateInfoEXT(IOSURFACE)`,
   render a triangle into it, `vkExportMetalObjectsEXT` → IOSurfaceRef.
2. `IOSurfaceCreateMachPort` → second process →
   `IOSurfaceLookupFromMachPort` → set as `CALayer.contents` in a bare
   NSWindow. Confirm pixels appear and update when re-rendered.
3. Measure surface-flip latency vs the msl `GuiSurface` memcpy baseline for
   a 2560×1600 frame (informational).

Accept: cross-process IOSurface presentation works from a MoltenVK-rendered
image. (Research says yes; this is cheap insurance before G6 depends on it.)

### G0.5 — Baseline numbers for acceptance gates

On the same hardware, record the **current msl** numbers (build from source,
`make host sign guest initramfs`, install a distro):
- glmark2 (llvmpipe) score in an msl distro.
- GuiLedger p50/p95 commit→present and input→present for: terminal editor
  (small damage), 1080p video-style full-window damage, window resize storm
  (use existing CSV harness, `gui-<distro>.csv`).
- `msl` VM boot-to-ready time, daemon memory footprint.

These become the "before" column in 14-validation §targets.

### G0.6 — Spike report + risk updates

Write `docs/reports/gpu-g0-spike.md` (untracked docs area) with: hardware,
versions (krunkit/libkrun/virglrenderer/MoltenVK/KosmicKrisp/guest
kernel/Mesa), all recorded outputs, pass/fail per item, and the chosen
defaults (host ICD, guest Mesa pin, format list). Update
15-risks-and-contingencies.md statuses. Update the README status ledger.

## Exit criteria

- G0.1 pass (hard gate).
- G0.2–G0.4 outcomes recorded with chosen defaults.
- Baselines captured (G0.5).
- Risk register updated; go decision recorded in 03-decision.md §status.
