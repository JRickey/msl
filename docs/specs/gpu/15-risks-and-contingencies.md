# 15 — Risk Register

Update statuses as milestones land (owner: whoever executes the milestone).

| ID | Risk | Likelihood | Impact | Trigger/test | Mitigation / contingency | Status |
|---|---|---|---|---|---|---|
| R-1 | Venus **rendering** (WSI/draw) unstable under libkrun+MoltenVK (public record is compute-heavy) | Med | Program-critical | G0.1 | Co-develop fixes with libkrun/virglrenderer upstream (active, friendly projects); fall back to UTM's virglrenderer branch (further along on rendering); worst case: ship Vulkan-compute + GL-2.1-only first, GUI accel later | Open — G0 gates |
| R-2 | Zink GL too low for target apps (MoltenVK 2.1 cap) and KosmicKrisp immature | Med | High (G-2 goal) | G0.2 | Ship Vulkan-first + document GL levels; KosmicKrisp as fast-moving upgrade path (LunarG conformant, Google-funded); optional ANGLE-in-guest for GLES toolkits (16-future) | Open — G0 measures |
| R-3 | libkrun 2.0 API churn breaks vendored snapshot (krunkit #106-class) | High | Med (build churn) | Each pin bump | Vendor exact snapshot + patches; only deliberate bumps; fallback: pin 1.19.x + backport `krun_set_kernel`/initrd | Open |
| R-4 | External-initramfs unsupported in vendored libkrun | Med | Low | G3.1 | G2.4 option 2: embed initramfs via `CONFIG_INITRAMFS_SOURCE` (costs dev-loop convenience only) | Open |
| R-5 | Fork treadmill: slp virglrenderer + guest Mesa patches don't upstream | Med | Med (maintenance) | Watch MR !1583, Mesa MRs, UTM QEMU series | We already pin+vendor; patches are small; ecosystem (RedHat/UTM/LunarG) is actively pushing upstream — ride it | Open |
| R-6 | virglrenderer venus without render-server isolation: host VK crash kills msl-vmm (whole GPU VM) | Med | Med (UX) | Soak tests G6/G9 | Acceptable v1 (blast radius = GPU VM, daemon recovers); enable render-server when the fork supports it on macOS | Accepted v1 |
| R-7 | 16 KiB host-page alignment bugs surface despite patched Mesa | Med | Med | G4.5/G9 F-suite | Pinned Mesa carries alignment patch (shipping practice); contingency: 16K guest-page kernel profile (G2 §page-size) | Open |
| R-8 | virtiofs semantics differences break `/mnt/mac` workflows on GPU VM (podman #27679-class) | Med | Med | G3.4 | `permissionSemantics` tuning + agent mount options; document differences; worst case keep heavy `/mnt/mac` use on VZ distros | Open |
| R-9 | libkrun project health (recently moved orgs; small maintainer set) | Low | High long-term | Ongoing | Apache-2.0 → we can hard-fork; abstraction seam (G1) keeps a future Option-F/VZ-custom-device swap cheap | Open |
| R-10 | Dual-VM memory footprint unacceptable on 8–16 GiB Macs | Med | Med | G7.3 measurements | Idle-stop both VMs (exists); GPU VM boots only when a gpu distro is used; vram window sized conservatively; document | Open |
| R-11 | Hardened-runtime/library-validation friction signing 5+ dylibs + hypervisor entitlement | Low | Med (release) | G8.2 | Same-team Developer ID signing of all dylibs (standard practice: UTM, Docker, podman all ship this shape); dev builds ad-hoc sign | Open |
| R-12 | Explicit-sync gaps: EXPORT_SYNC_FILE insufficient for some clients → stale/torn frames | Med | Med | G0.3 + G5.5 soak | Add linux-drm-syncobj-v1 server support in msl-way (small protocol); last resort per-commit `vkQueueWaitIdle`-equivalent in guest (correct, slower) | Open |
| R-13 | Smithay 0.7 dmabuf/feedback API gaps | Med | Low | G5.1 | Implement protocol globals by hand (msl-way already hand-rolls its transport; dmabuf v3 global is small); or bump Smithay | Open |
| R-14 | apple/container or macOS adds first-party Linux GPU (obsoletes stack) | Low | Positive | WWDC watch | Celebrate; VMBackend seam absorbs it (Option F path) | Open |
| R-15 | GPU distros can't run x86-64 (no Rosetta) surprises users | High | Low (docs) | Support load | Hard validation + clear error + docs; FEX evaluation in 16-future | Open |

## Standing invariants (check at every milestone)

- VZ path bit-identical when no gpu distro exists.
- All fetches sha256-pinned; no GPL in the app bundle; license file current.
- Protocol changes negotiated; old/new peer matrix tested.
- Any new host dependency: Apache/MIT/BSD only.
