# msl GPU Virtualization — Specification and Roadmap

Status: **Accepted design, pre-implementation.**
Scope: replace/augment msl's virtualization layer so Linux GUI applications
run with real GPU acceleration and present into native macOS windows.
Audience: implementing agents and humans. Every milestone document is written
so that an agent with access to this repository (and no memory of this
research) can execute it end to end.

## Reading order

| Doc | Contents |
|---|---|
| [00-scope-and-goals.md](00-scope-and-goals.md) | Problem statement, goals, non-goals, hard requirements |
| [01-current-architecture.md](01-current-architecture.md) | As-is map of msl's virtualization + GUI pipeline, with file references |
| [02-research-findings.md](02-research-findings.md) | Verified state of the world: Apple VZ/`container`, libkrun, QEMU, Venus/Zink, Rosetta — with sources |
| [03-decision.md](03-decision.md) | Options analysis and the accepted decision (ADR) |
| [04-target-architecture.md](04-target-architecture.md) | End-to-end target design: components, data planes, sync model |
| [05-milestone-g0-spike.md](05-milestone-g0-spike.md) | G0 — de-risking spike (validate Venus/Zink on macOS before building) |
| [06-milestone-g1-backend-abstraction.md](06-milestone-g1-backend-abstraction.md) | G1 — extract `VMBackend` protocol; VZ backend unchanged |
| [07-milestone-g2-kernel.md](07-milestone-g2-kernel.md) | G2 — self-built kernel with virtio-gpu (msl-kernel `make build`) |
| [08-milestone-g3-vmm.md](08-milestone-g3-vmm.md) | G3 — `msl-vmm`: libkrun-based GPU VM host process + device mapping |
| [09-milestone-g4-guest-gpu-userland.md](09-milestone-g4-guest-gpu-userland.md) | G4 — Mesa (Venus/Zink) guest userland, build + projection + env |
| [10-milestone-g5-way-protocol.md](10-milestone-g5-way-protocol.md) | G5 — msl-way dmabuf support, explicit sync, GUI protocol extensions |
| [11-milestone-g6-host-presentation.md](11-milestone-g6-host-presentation.md) | G6 — host presentation: copy path, then zero-copy IOSurface |
| [12-milestone-g7-daemon-integration.md](12-milestone-g7-daemon-integration.md) | G7 — daemon dual-VM orchestration, distro placement, CLI, memory |
| [13-milestone-g8-packaging-ci.md](13-milestone-g8-packaging-ci.md) | G8 — build system, dependency vendoring, signing, licensing, CI |
| [14-validation-and-performance.md](14-validation-and-performance.md) | Test matrix, acceptance gates, performance targets, latency harness |
| [15-risks-and-contingencies.md](15-risks-and-contingencies.md) | Risk register with triggers and fallbacks |
| [16-future-work.md](16-future-work.md) | macOS 27 `VZCustomVirtioDevice` reunification, FEX, audio, native context |

## One-paragraph summary

Apple's Virtualization.framework offers no 3D acceleration for Linux guests
(verified current through the macOS 27 beta), and Apple's own `container`
stack has declined to add it. The only shipping GPU path for Linux guests on
macOS is libkrun's virtio-gpu **Venus** (Vulkan) device rendered through
virglrenderer → MoltenVK/KosmicKrisp → Metal. msl therefore moves to a
**dual-backend architecture**: the existing Virtualization.framework backend
remains (it is the only legal Rosetta carrier and the mature default), and a
new **`msl-vmm`** child process embedding **libkrun** provides a second,
GPU-capable utility VM. The guest gains a self-built kernel with
`CONFIG_DRM_VIRTIO_GPU`, an msl-shipped Mesa (Venus ICD + Zink GL) projected
into distros through the existing `/run/msl/tools` mechanism, and `msl-way`
learns `linux-dmabuf` + explicit sync so client GPU buffers travel to the host
as virtio-gpu resource references instead of pixel copies. On the host, the
rendered VkImage is exported as an IOSurface (`VK_EXT_metal_objects`) and
handed to the existing `msl-presenter` CALayer pipeline via mach port —
zero-copy end to end. Rosetta-enabled distros stay on the VZ VM; GPU-enabled
distros run on the krun VM; the daemon orchestrates both.

## Conventions used in these documents

- File references are `path:line` against the repository at the time of
  writing (branch point: `main` @ `ff8382c`). Line numbers drift; symbol names
  are authoritative.
- Milestones are labeled G0…G9. Each has **Entry criteria**, **Work items**
  (numbered, with acceptance criteria), and **Exit criteria**. Work items are
  sized so one agent session can complete one item.
- "VZ backend" = today's Virtualization.framework path. "krun backend" = the
  new libkrun path. "GPU VM" = the utility VM booted by the krun backend.
- External claims cite sources in 02-research-findings.md; implementation
  docs do not repeat citations.

## Status ledger

Maintained by implementers; update when a milestone lands.

| Milestone | Status |
|---|---|
| G0 spike | not started (needs macOS hardware) |
| G1 backend abstraction | implemented (commits 08af620, 03a24e1, +G1.4/G1.5); awaiting macOS CI build/test validation and the G1 hardware spot-check |
| G2 kernel | not started |
| G3 msl-vmm | not started |
| G4 guest userland | not started |
| G5 way/protocol | not started |
| G6 host presentation | not started |
| G7 daemon integration | not started |
| G8 packaging/CI | not started |
| G9 validation | not started |
