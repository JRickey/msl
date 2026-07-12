# 09 — Milestone G4: Guest GPU Userland (Mesa, env, projection)

Goal: distros on the GPU VM get a working Vulkan (Venus) ICD and Zink GL
without any per-distro package installation, via msl-shipped artifacts
projected at `/run/msl/tools`. `vulkaninfo` and `glxinfo`/`eglinfo` succeed
in a stock Ubuntu distro at the end of this milestone.

## Entry criteria

- G3.6 (venus capset visible in the GPU VM).
- G0 report (Mesa pin + required patches + host ICD choice).

## Design decisions

### D1 — How Mesa is built (linkage model)

Mesa cannot realistically be a static-musl binary like msl's Rust tools (it
dlopen's, is dlopen'd, and needs a libc that matches the *client app's*
runtime). Options:

- **(chosen) glibc sysroot build, oldest-supported baseline.** Build Mesa in
  the **builder VM** (Alpine builder initramfs is musl — insufficient;
  instead use a pinned Debian 12 / Ubuntu 22.04 rootfs as a *gpu-builder*
  image, glibc 2.35 baseline) targeting aarch64-linux-gnu. Artifacts are
  relocatable via `-Dprefix=/run/msl/tools/gpu` at configure time (Mesa
  hardcodes some paths; setting the final prefix to the projected path makes
  ICD/driver json self-consistent). Any distro with glibc ≥ baseline loads
  them; musl distros (alpine) fall back to llvmpipe (documented).
- Rejected: zig-cc musl cross (Mesa+LLVM under zig cc is a science project);
  per-distro packages (violates "no distro mutation"); flatpak-style
  runtime (heavyweight).

New builder flow: `tools/mk-mesa.sh` drives `msl boot` with the
gpu-builder rootfs (same in-VM build pattern as `mk-rootfs.sh`), running a
pinned meson build inside; output tarball → staged into initramfs by
`mk-initramfs.sh` under `/tools/gpu/`. All sources sha-pinned; Mesa version
+ patch set from G0 (expect: Mesa 25.x + 16KiB-alignment patch + any slp
patches not yet upstream; vendor patches under `tools/patches/mesa/`).

Build config (first cut):

```
meson setup build \
  -Dprefix=/run/msl/tools/gpu \
  -Dplatforms=wayland,x11 -Degl=enabled -Dglx=dri -Dgbm=enabled \
  -Dvulkan-drivers=virtio \
  -Dgallium-drivers=zink,llvmpipe \
  -Dvulkan-icd-dir=/run/msl/tools/gpu/share/vulkan/icd.d \
  -Dbuildtype=release
```

(llvmpipe included so the fallback also comes from our pinned Mesa when the
GPU env is active but venus probing fails; distro Mesa remains the default
fallback otherwise.) Dependencies inside gpu-builder: libdrm (pinned),
wayland/x11 headers, LLVM for llvmpipe — resolved by the pinned builder
rootfs snapshot.

### D2 — GL strategy

- Vulkan apps: Venus ICD directly (`VK_DRIVER_FILES` pins our ICD json).
- GL apps: **Zink** via our Mesa (`MESA_LOADER_DRIVER_OVERRIDE=zink`,
  `GALLIUM_DRIVER=zink`, `LIBGL_DRIVERS_PATH`/`__EGL_VENDOR_LIBRARY_DIRS`
  pointing into `/run/msl/tools/gpu`). GL level depends on host ICD
  (MoltenVK ≈ 2.1, KosmicKrisp ≥ 3.3 — G0 measured); env only, no protocol
  impact.
- glvnd: distros ship libglvnd; our EGL vendor json slots in via
  `__EGL_VENDOR_LIBRARY_DIRS` without touching distro files. GLX: our
  `libGLX_mesa` is selected only when env-directed; do not fight distro
  alternatives — GLX apps on X11/Xwayland will typically route via
  Xwayland+EGL anyway. Validate with `glxgears`, `eglinfo`, `es2_info`.

### D3 — /dev/dri into distros

The agent creates distro namespaces without device isolation today (no
CLONE_NEWNET/USER; `/dev` handling in `child_boot`, `sys.rs:529+`). Work:
bind-mount host `/dev/dri` into the distro `/dev/dri` during `child_boot`
when the VM has one (presence-gated, so VZ VM distros see nothing). Ensure
node ownership/permissions: render node is 0666 by convention (`udev` isn't
running in the utility VM initramfs context for distro boot — set explicit
chmod in agent). systemd-udev inside the distro may also create nodes from
uevents since devtmpfs is shared — verify no conflict; if distro udev
renders `/dev/dri` itself, presence-gating is enough.

## Work items

### G4.1 — gpu-builder image + mk-mesa.sh
Pinned Debian/Ubuntu builder rootfs (sha-pinned tarball fetch, mk-rootfs.sh
pattern), `tools/mk-mesa.sh` producing `build/gpu-tools.tar` with the layout:

```
gpu/lib/            libvulkan_virtio.so, libgbm.so.1, dri/zink_dri.so (or
                    libgallium-25.x.so + megadriver links), libEGL_mesa.so.0,
                    libGLX_mesa.so.0, swrast bits
gpu/share/vulkan/icd.d/msl-venus.aarch64.json
gpu/share/glvnd/egl_vendor.d/50_msl_mesa.json
gpu/bin/            vulkaninfo, vkcube, glxinfo, eglinfo, glmark2? (dev-only,
                    behind MSL_GPU_TOOLS=1 staging flag; keep release lean)
```

Acceptance: tar builds reproducibly; `ldd` of every .so resolves within
{tar, glibc baseline}.

### G4.2 — Initramfs + projection
`mk-initramfs.sh` gains optional `GPU_TOOLS_TAR` input staging it under
`/tools/gpu` (`REQUIRE_GPU_TOOLS=1` for release-runtime of the GPU flavor).
Confirm the existing `/tools` → `/run/msl/tools` projection covers the
subtree (it bind-mounts the dir — it does). Size check: record initramfs
growth; if > ~120 MiB compressed becomes a problem for VZ VM memory,
split: `/tools/gpu` only in the GPU VM's initramfs (two initramfs assets;
Makefile + MSLHome resolution fork). Decide based on measurement, document.

### G4.3 — Agent: /dev/dri projection + gpu_probe
- `child_boot` bind of `/dev/dri` (presence-gated) + chmod policy.
- New control op `gpu_probe` (agent, `server.rs` op table): reports
  `{dri: bool, venus: bool, mesa: "25.x-msl"}` — venus checked by opening
  the render node and querying the capset (small direct ioctl, no Mesa
  dependency). Used by daemon/CLI status and env decisions.
- Unit-style test where feasible; manual acceptance in G4.5.

### G4.4 — Env switch (both sides, kept in sync)
- `guest/agent/src/gui.rs gui_env()`: branch on GPU availability (agent
  knows from its own probe; cache at runtime start):
  - GPU: `VK_DRIVER_FILES=…msl-venus.aarch64.json`,
    `__EGL_VENDOR_LIBRARY_DIRS=…egl_vendor.d`,
    `LIBGL_DRIVERS_PATH=…gpu/lib/dri`,
    `MESA_LOADER_DRIVER_OVERRIDE=zink`, `GALLIUM_DRIVER=zink`,
    (no `LIBGL_ALWAYS_SOFTWARE`).
  - non-GPU: exactly today's llvmpipe set.
- Host mirror `GuiRuntime.swift env` + `GuiRuntimeTests` updated to cover
  both branches (the sync test at `GuiRuntimeTests.swift:11` becomes two
  cases; keep the mirror-contract comment).
- Session env (`msl shell`/`run`, non-GUI) also gets the VK/EGL vars in GPU
  distros (headless compute counts): decide the injection point in agent
  session setup, same branch source.

### G4.5 — In-distro validation (hardware)
Stock Ubuntu catalog distro, `--gpu on`:
- `vulkaninfo --summary` → Venus device; `vkcube` headless run OK (window
  path arrives with G5).
- `eglinfo`/`glxinfo -B` → zink renderer string, expected GL level per host
  ICD; `LIBGL_ALWAYS_SOFTWARE` absent.
- Alpine (musl) distro: graceful fallback to llvmpipe with a status note in
  `msl status`/`gpu_probe`.
- Record versions + outputs in the PR.

## Exit criteria

- Stock distro passes G4.5 with zero in-distro installs.
- VZ-VM distros unaffected (env branch verified by tests).
- All new fetches sha-pinned; gpu-tools tar reproducible; initramfs size
  decision recorded.
