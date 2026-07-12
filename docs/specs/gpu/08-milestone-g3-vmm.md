# 08 — Milestone G3: msl-vmm (the krun backend)

Goal: a supervised child process that boots the GPU VM via libkrun with
virtio-gpu (Venus), exposes vsock ports as unix sockets, and plugs into the
daemon behind `KrunBackend: VMBackend`. At exit of G3 the GPU VM runs
distros headlessly with full msl semantics (shell/run/forwarding/shares) —
GPU userland and GUI come in G4/G5.

## Entry criteria

- G1 merged (VMBackend seam exists).
- G2 usable kernel Image (fetch-mode Kata Image is acceptable for early
  G3 work items that don't touch the GPU, but G3.6+ needs the G2 kernel).
- G0 report for version pins.

## Vendoring libkrun (G3.1 — the load-bearing item)

Decision inputs (02 §4): libkrun 1.19.x is stable but macOS boot = libkrunfw
(GPL bundle, wrong kernel) or EFI (wrong boot model for msl); libkrun `main`
(2.0) has `krun_set_kernel` (direct kernel boot) + display/input backends but
is a moving target.

Plan of record:
1. Vendor a **pinned snapshot of libkrun 2.0 main** as
   `third_party/libkrun/` metadata (commit hash + sha256 of source tarball;
   built by `tools/mk-libkrun.sh`, artifacts under `build/host-deps/`).
   Justification: `krun_set_kernel` (R4) and the display API (G6 option) only
   exist there; podman-era 1.x would force EFI + disk-image boot, which
   breaks msl's initramfs/agent model — a bigger fork burden than tracking
   2.0. Re-evaluate at each bump; if 2.0 churn bites (krunkit #106-class
   breakage), fall back to 1.19.x + a small backport patch of
   `krun_set_kernel`+initrd (both variants must be assessed in this work
   item and the choice recorded here).
2. Verify/implement **external initramfs**: if the snapshot's
   `krun_set_kernel` lacks an initrd parameter, carry a patch
   (`third_party/libkrun/patches/0001-initrd.patch`) or switch G2.4 to the
   embedded-initramfs option. Record outcome in 07-milestone-g2 §G2.4.
3. Build recipe `tools/mk-libkrun.sh`: cargo build (aarch64-apple-darwin,
   release), produces `libkrun.dylib` + headers; deps: vendored
   virglrenderer (below), MoltenVK from a pinned release. sha-pin every
   fetched source (repo convention).
4. virglrenderer: `tools/mk-virglrenderer.sh` building the **slp fork tag
   0.10.4e-krunkit** (meson `-Dvenus=true -Drender-server=false`,
   deps molten-vk, libepoxy) — exactly the brew formula recipe, vendored and
   pinned. Track upstream MR !1583; when merged, repoint to upstream and
   drop the fork (15-risks R-5).
5. MoltenVK: pinned release ≥ 1.3.0 (VK_EXT_external_memory_metal;
   VK_EXT_metal_objects). KosmicKrisp: optional second ICD — pinned Mesa
   26.x host build with `-Dvulkan-drivers=kosmickrisp` via
   `tools/mk-kosmickrisp.sh` (G0 decided whether it ships in v1 or stays a
   dev flag).

Acceptance G3.1: `make host-deps` builds all of the above reproducibly on a
clean mac (CI job in G8); a 20-line C/Swift harness boots a busybox initramfs
to a shell prompt via the vendored libkrun (proves kernel+initrd path).

## msl-vmm process (G3.2)

New SwiftPM executable target `msl-vmm` (Package.swift; depends MSLCore +
CMSLSys; links libkrun via a new C shim target `CKrun` with a modulemap;
**no AppKit**).

Config document (fd 3, JSON, one shot):

```json
{
  "kernel": "~/.msl/kernel", "initramfs": "~/.msl/initramfs.cpio",
  "cmdline": "console=hvc0",
  "cpus": 4, "memoryMiB": 4096, "vramMiB": 4096,
  "disks": [{"path": "~/.msl/distros/ubuntu.img", "readOnly": false}],
  "shares": [{"tag": "mac", "path": "/Users/x", "readOnly": false}],
  "vsock": {
     "dir": "~/.msl/run/gpuvm",
     "hostConnectPorts": [5000,5001,5002,5003,5020,5030],
     "guestConnectPorts": [5010,5040]
  },
  "net": {"mode": "gvproxy", "socket": "~/.msl/run/gpuvm/net.sock"},
  "gpu": {"enabled": true, "icd": "moltenvk"},
  "console": "~/.msl/logs/gpuvm-console.log"
}
```

Sequence: parse config → `krun_create_ctx` → `krun_set_vm_config` →
`krun_set_kernel(+initrd,+cmdline)` → disks (`krun_add_disk`) → virtiofs
(`krun_add_virtiofs`) → net → vsock port maps → `krun_set_gpu_options2`
(VENUS|NO_VIRGL, vram) → `krun_set_console_output` → emit `ready` on fd 4 →
`krun_start_enter()` (never returns). Signals: SIGTERM handler requests
guest shutdown via libkrun (or closes with grace timeout → `_exit(143)`).

Environment for the ICD: set `VK_DRIVER_FILES` before `krun_start_enter`
per `gpu.icd` (MoltenVK ICD json vendored next to the dylib; KosmicKrisp
alternative). `DYLD` search paths resolved at signing time via rpath —
dylibs live in `msl.app/Contents/Frameworks/` (G8).

Acceptance G3.2: launched by hand with a config, boots the msl initramfs,
`ready` emitted, agent reachable: `socat - UNIX-CONNECT:$RUN/vsock-5000.sock`
speaks the length-prefixed ping (replicate `VsockClient` framing) — or
simpler, a new `msl-vmm --selftest` mode does the ping internally.

## KrunBackend proxy in the daemon (G3.3)

`host/Sources/MSLCore/KrunBackend.swift`:
- `startAndWait`: spawn msl-vmm (reuse the `GuiPresenterLauncher` spawn
  pattern — `posix_spawn`, SETSID, CLOEXEC_DEFAULT, fd 3 config / fd 4
  events), wait for `ready` (timeout → kill + error). `onStop` wired to
  process exit + `stopped` event.
- `connectRaw(port:)`: connect `$RUN/vsock-<port>.sock`, return fd —
  everything above (VsockClient/ByteRelay/DataPlane/PortForwarder/GUI
  attach) is already fd-generic.
- Reverse listeners: msl-vmm side listens on the mapped unix sockets and
  relays accepted fds over the control channel (`SCM_RIGHTS` over a unix
  socketpair established at spawn, fd 5). `KrunBackend` receives fds and
  invokes the `ReverseVsockHandler`s registered via `setReverseListener`.
  (Simpler alternative if libkrun's vsock guest-connect mapping allows the
  *daemon* to own the listening unix socket directly: pass the socket path
  into msl-vmm config and skip fd relay. Investigate first; prefer the
  simpler wiring.)
- `setMemoryTarget`: forwards a `reclaim {mib}` control message → msl-vmm
  (libkrun FPR + agent `mem_reclaim` op) — exact semantics in G7.
- capabilities: `{kind: .krun, rosetta: false, gpu: true,
  balloon: .freePageReporting}`.

Acceptance G3.3: with `BootSpec(backend: .krun)`, `DaemonCore` boots the GPU
VM; `msl boot --backend krun --exec 'echo m0-ok'` (direct path) prints
m0-ok; unit tests for spawn/ready/stop state machine with a fake msl-vmm
(shell script emitting the fd-4 protocol).

## Full plumbing parity (G3.4)

Run the existing surfaces against the krun backend on hardware:
- `distro_up`, `msl shell/run` exit codes (control 5000 + PTY 5001).
- Port forwarder (5003) mirrors a guest listener to 127.0.0.1.
- `/mnt/mac` share read/write via virtiofs (`permissionSemantics=complete`
  equivalent — validate uid/gid behavior; podman #27679-class friction goes
  in a compat note + agent mount options).
- Interop `mac` shim (5010 reverse) and auth bridge (5040 reverse).
- Logs plane (5002), console log file.
- FSKit plane (5030): mount a krun-hosted distro in Finder.

Acceptance: a checklist run recorded in the PR description; fskit-e2e.sh
against a krun-backed distro passes read-only + read-write.

## Networking (G3.5)

Vendor gvproxy (Apache-2.0, static Go binary) as `msl-gvproxy` or implement
a minimal passt-style relay later; msl-vmm spawns/owns it (child of msl-vmm,
dies with it), unix-dgram socket wiring per krunkit's usage doc. DNS +
outbound TCP/UDP verified from a distro (`apt update`). No inbound port
mapping via the proxy (vsock forwarder covers inbound).

## GPU device smoke (G3.6)

With the G2 kernel: `/dev/dri/renderD128` exists in the GPU VM;
`DRM_IOCTL_VIRTGPU_GET_CAPS` reports the VENUS capset (use a tiny compiled
probe in the initramfs `/tools`, or `cat /sys/kernel/debug/dri/…` if
enabled). No Mesa yet — this is the device-level gate for G4.

## Exit criteria

- `msl config <d> --gpu on && msl run <d> -- uname -a` works end to end on
  hardware (placement logic may be interim: a dev env var
  `MSL_FORCE_BACKEND=krun` is acceptable until G7 lands real placement).
- All G3.4 parity checks pass; VZ path untouched (CI + smoke).
- Vendored deps build reproducibly; pins recorded in `tools/mk-*.sh`.
- Risk register updated (libkrun variant chosen, initramfs strategy locked).
