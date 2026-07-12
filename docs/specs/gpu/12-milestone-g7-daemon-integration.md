# 12 — Milestone G7: Daemon Dual-VM Orchestration & Productization

Goal: the daemon manages both backends as first-class citizens: placement,
lifecycle, memory, status, CLI/menubar surfaces, and the failure ladder.
After G7, `--gpu on` is a supported user feature (still default-off).

## Entry criteria

- G3 (krun backend works), G6.1 minimum (GUI usable); G6.2 may land in
  parallel.

## Placement model

- Per-distro `gpu: Bool` (config JSON + registry, landed inert in G1.5).
  Validation: `gpu` ⇒ `!rosetta` (both directions, at `msl config` time and
  at `distro_up` time with a clear error).
- Backend of a distro = `gpu ? .krun : .vz`. No auto-migration; changing the
  flag requires the distro stopped (same UX as `--rosetta`,
  `DaemonCore+Rosetta` pattern).
- `DaemonCore` state: `hosts: [VMBackendKind: BackendRuntime]` where
  `BackendRuntime` = today's (host, control, deviceMap, forwarder,
  listeners, balloon/ladder state) tuple — i.e., the current single-VM
  fields become a keyed struct. Session/GUI/mount/forward tables gain the
  backend key via the distro (they're distro-keyed already; distro→backend
  is a lookup).
- Lazy boot per backend on first distro/op that needs it; idle-stop per
  backend with the same `IdlePolicy` (60 s) evaluated independently.
  `msl shutdown` stops both. `msl status` lists per-VM state, memory,
  distro placement, and GPU availability (`gpu_probe` results).

## Work items

### G7.1 — DaemonCore multi-backend refactor
Mechanical but wide: extract `BackendRuntime`, key by kind, thread through
`+Lifecycle`, `+GUI`, `+FSMount`, `+Rosetta`, forwarding, memory ladder,
poll timer (2 s `net_listeners` per running VM), `handleStop` (per-VM).
Unit tests: placement resolution, dual idle-stop, boot failure isolation
(krun boot failure must not affect VZ ops). This is the highest-regression-
risk item of G7; do it as its own PR with no behavior additions.

### G7.2 — Device map / disks
`DeviceMap` (distro→/dev/vdX) becomes per-backend; distro images attach
only to their backend's VM at its boot. Install/export builder flows remain
VZ-only and unchanged. Catalog/local installs default `gpu=false`; add
`msl install <sel> --gpu` convenience that sets the flag before first boot.

### G7.3 — Memory policy for the GPU VM
- VZ VM: existing ladder + balloon untouched.
- GPU VM sizing: default `memoryMiB` same policy as VZ VM; `vramMiB`
  default `min(8192, hostRAM/4)` (config key `gpu.vramMiB`, per-user config
  `~/.msl/config.json` global section).
- Reclaim: `setMemoryTarget` on krun maps to agent `mem_reclaim` (existing
  op: drop caches) + libkrun free-page reporting returning pages; expose
  msl-vmm RSS in status (proc info via the daemon on the child pid).
  Explicitly document that GPU VM memory is not balloon-clamped; idle-stop
  is the primary reclaim (unchanged 60 s idle behavior matters more here —
  verify GUI-runtime grace interactions: a lingering presenter must not pin
  an idle GPU VM forever; existing `guiPresenterGrace`/session reaping
  already covers this — test it).

### G7.4 — CLI/UX surfaces
- `msl config <d> --gpu on|off` (finalize; help text incl. Rosetta
  exclusivity and requirements), `msl status` additions, `msl desktop
  probe` reports GPU path, `msl gui` diagnostics extended (`gpu_probe`,
  negotiated caps, ledger path column).
- Menubar (msl-menubar): settings toggle per distro (mirrors CLI; reuse
  existing per-distro settings UI), VM rows show both VMs.
- Docs: README "GUI Direction" + constraints sections updated (remove
  "no GPU acceleration" constraint, describe opt-in + Rosetta exclusivity);
  skills/msl SKILL.md gains a GPU section (`msl config <d> --gpu on`,
  troubleshooting basics) — keep consumer-skill tone.

### G7.5 — Failure ladder wiring
Implement 04 §8: krun-down error strings actionable; `gpu_probe` fallback
to llvmpipe env (G4.4 branch) exercised by disabling the GPU device in a
test boot; `MSL_GPU=off` per-invocation escape hatch (documented env the
launcher/agent respects when composing `gui_env`).

### G7.6 — Concurrency/interop matrix on hardware
- VZ distro + GPU distro running simultaneously: shells, forwards, FSKit
  mounts on both; `mac` interop from both; clipboard-free GUI apps from
  both presenting concurrently.
- Rosetta distro regression suite on VZ while GPU VM active.
- Kill -9 msl-vmm mid-frame: daemon marks krun down, presenter tears down
  runtime windows gracefully, VZ unaffected; restart works.

## Exit criteria

- Dual-VM daemon passes the matrix; single-VM users see zero change.
- `--gpu` documented and validated; status/menubar surfaces live.
- Memory behavior measured and documented (idle footprints of both VMs in
  14-validation numbers).
