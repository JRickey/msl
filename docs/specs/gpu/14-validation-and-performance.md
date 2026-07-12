# 14 — Validation and Performance (G9)

G9 is the certification milestone: run everything below, fill in the
numbers, and flip defaults/docs accordingly. Baselines come from G0.5.

## Test matrix

### Functional — GPU path

| # | Test | Pass condition |
|---|---|---|
| F1 | `vulkaninfo --summary` in GPU distro | Venus device, VK ≥ 1.2, msl ICD path |
| F2 | `vkcube` (Wayland WSI) windowed | ≥60 fps @ default size, correct render, 10-min soak no hang/leak |
| F3 | `vkmark` | completes all scenes, score recorded |
| F4 | `glxinfo -B` / `eglinfo` | zink renderer, GL level per host ICD recorded |
| F5 | glmark2 (wayland) | ≥5× llvmpipe baseline (G0.5), no artifacts |
| F6 | GTK4 demo + Qt6 Quick app | GL contexts on zink, correct rendering, resize/popup correctness |
| F7 | Xwayland GL (`glxgears`, an X11 game) | renders via dmabuf path; override-redirect popups fine |
| F8 | Mixed SHM+GPU clients one runtime | both correct; pacing stable |
| F9 | Window ops on GPU surfaces | resize storm, minimize/restore, fullscreen, multi-display move, HiDPI scale change, dark-mode — no stuck frames/size verdicts |
| F10 | Vulkan compute (llama.cpp ggml-vulkan or vkpeak) | completes; tokens/s or GFLOPS recorded |
| F11 | Cursor: named + (if landed) image cursors over GPU windows | correct |
| F12 | 4K fullscreen vkcube | no starvation; pacer holds; ledger sane |

### Functional — regression (must be unchanged vs main)

| # | Area |
|---|---|
| R1 | VZ distro full CLI suite: install/list/shell/run exit codes/stop/export/import |
| R2 | Rosetta distro on VZ (x86-64 binary runs; GPU flag rejected while rosetta on) |
| R3 | SHM GUI path on VZ distro (ledger within noise of baseline) |
| R4 | Port mirroring both backends; `/mnt/mac` rw both; `mac` interop both |
| R5 | FSKit mount/read/write harness (`tools/fskit-e2e.sh`) on both backends |
| R6 | Idle-stop/lazy-boot both VMs; daemon restart recovery; `msl shutdown` |
| R7 | `.msl` export/import of a gpu-flagged distro (flag round-trips; imports on non-GPU-capable host degrade cleanly) |
| R8 | Builder VM install/export flows (VZ) |

### Fault injection

| # | Test |
|---|---|
| X1 | kill -9 msl-vmm during vkmark → daemon marks krun down; windows close; VZ unaffected; next `--gpu` op reboots GPU VM |
| X2 | kill presenter during GPU playback → 60 s grace reattach works (existing `guiPresenterGrace`) |
| X3 | Boot GPU VM with GPU disabled (config) → gpu_probe false, llvmpipe env, GUI works via SHM |
| X4 | Corrupt/mismatched Mesa (simulate old distro glibc) → fallback + status note, no crash |
| X5 | Guest OOM under vram pressure (alloc storm) → VM survives or restarts cleanly, host stable |
| X6 | Protocol: fuzz T_COMMIT_GPU fields host-side (existing parser-test style) → no presenter crash |

## Performance targets (fill at G9; baselines from G0.5)

| Metric | Baseline (llvmpipe/SHM) | Target (GPU) | Measured |
|---|---|---|---|
| glmark2 score | b₁ | ≥5×b₁ | |
| vkmark score | n/a | recorded | |
| commit→present p95, 1080p full-damage | b₂ | ≤b₂ (G6.1) / ≤0.5×b₂ (G6.2) | |
| input→present p95 | b₃ | ≤b₃ | |
| msl-vmm CPU% fullscreen vkmark | n/a | G6.2 ≪ G6.1 (recorded) | |
| GPU VM boot-to-ready | VZ: b₄ | ≤b₄ + 1 s | |
| Idle RSS: daemon+VZ VM / +GPU VM | b₅ | recorded; GPU VM idle-stops | |
| llama.cpp pp512/tg128 vs native Metal | n/a | ≥60 % (stretch 75 %) | |

Measurement tooling: existing `GuiLedger` CSV (extended with path column,
G6.1), `msl status` memory, Instruments for leaks/CPU. All runs documented
with hardware + macOS + pin versions in `docs/reports/gpu-g9-cert.md`.

## Acceptance gates to flip

1. All F/R/X pass on at least M2- and M4-class hardware, macOS 26.
2. Performance table filled; no target missed without a signed-off waiver
   note in this file.
3. README + SKILL.md updated (G7.4) and the "software rendering" constraint
   removed; status ledger in these specs marked complete.
4. Decide (explicitly, in 03-decision.md §status): whether `--gpu on`
   becomes default-on for new non-Rosetta installs (recommendation: stay
   opt-in for one release, then default-on if telemetry/issues are clean).
