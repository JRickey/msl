# 13 — Milestone G8: Build System, Packaging, Licensing, CI

Goal: everything builds from pinned sources, ships in the signed/notarized
pkg, and CI guards the whole program. Runs partly in parallel with G4–G7.

## Vendored host dependencies (new)

| Dep | Source pin | Built by | License | Ships as |
|---|---|---|---|---|
| libkrun (2.0 snapshot + msl patches) | commit sha + tarball sha256 | `tools/mk-libkrun.sh` (cargo, aarch64-apple-darwin) | Apache-2.0 | `Contents/Frameworks/libkrun.dylib` |
| virglrenderer (slp fork tag → upstream later) | tag + sha256 | `tools/mk-virglrenderer.sh` (meson) | MIT | `Contents/Frameworks/libvirglrenderer.dylib` |
| MoltenVK | release ≥1.3.x + sha256 | fetch prebuilt or `mk-moltenvk.sh` | Apache-2.0 | `Contents/Frameworks/libMoltenVK.dylib` + ICD json in `Resources/vulkan/icd.d` |
| libepoxy (virgl dep) | pin + sha256 | mk script | MIT | dylib in Frameworks |
| gvproxy | release pin + sha256 | fetch (static Go) | Apache-2.0 | `Contents/MacOS/msl-gvproxy` |
| KosmicKrisp (optional ICD) | Mesa 26.x pin | `tools/mk-kosmickrisp.sh` | MIT | dylib + ICD json (feature-flagged) |
| Vulkan-Loader (only if ICD switching needs it) | pin | mk script | Apache-2.0 | evaluate: MoltenVK can be linked directly by virglrenderer; prefer loader for ICD swapping |

Guest-side (from G4): gpu-builder rootfs pin, Mesa pin + patch set, libdrm
pin — inside `tools/mk-mesa.sh`.

Rules: every fetch sha256-verified (repo convention;
`tools/mk-libxkbcommon.sh` must also gain its missing sha pin while here);
`build/host-deps/` cache keyed by pin; `make host-deps` entry point;
`make clean` keeps dep cache, `make distclean` clears.

## Work items

### G8.1 — mk scripts + Makefile targets
All `tools/mk-*.sh` above; Makefile: `host-deps`, `msl-vmm` (swift build of
the target needs Frameworks rpath for dev runs — use
`-Xlinker -rpath -Xlinker @executable_path/../Frameworks` and a dev-layout
symlink under `.build/`), integrate into `all`/`release-runtime`.

### G8.2 — App bundle + signing
- `app` target: copy msl-vmm into `Contents/MacOS/`, dylibs into
  `Contents/Frameworks/`, ICD jsons into `Contents/Resources/vulkan/`.
- Entitlements: new `entitlements/vmm.entitlements` =
  `com.apple.security.hypervisor` (+ `get-task-allow` in dev variant).
  msl-vmm signed with it; daemon/CLI keep virtualization-only. Hardened
  runtime: dylibs must be signed individually (`codesign --force --options
  runtime` each, then the bundle; library validation stays on — all our
  dylibs are Developer-ID-signed with the same team). Update `sign`,
  `release-app` targets accordingly.
- Notarization: no change expected (no restricted entitlements); verify
  `spctl` pass with the hypervisor entitlement present.

### G8.3 — Licensing
- Regenerate `THIRD-PARTY-LICENSES` (tooling: `tools/third-party-licenses.hbs`
  + cargo-about for Rust deps; extend the generation to cover the vendored
  C/C++ deps — add a manifest file `tools/host-deps-licenses.json` consumed
  by the template). MoltenVK/libkrun Apache-2.0 NOTICE obligations: include
  upstream NOTICE files.
- Kernel: remains GPL in msl-kernel; if G2 release-artifact mode hosts a
  prebuilt Image on msl-kernel releases, that repo's release must include
  source + config (GPLv2 §3) — add a release checklist there.
- Confirm: no GPL/LGPL code enters the app bundle (gvproxy Apache, all
  dylibs MIT/Apache; **do not** ship libkrunfw).

### G8.4 — CI
- `ci.yml` additions: `make host-deps` (cached by pin hash), build msl-vmm,
  swift/cargo test suites incl. new proto tests; kernel: fetch-mode only in
  CI (self-build too slow) but lint the msl-kernel submodule pin against
  the expected artifact sha.
- New hardware-dependent tests stay manual/optional: gate behind
  `MSL_HW_TESTS=1` make target (`make gpu-e2e`) documented in 14-validation;
  macos-26 GH runners have no HVF nested support for real GPU work — do not
  attempt in CI.
- release.yml: host-deps built (or restored) before `release-pkg`;
  packaging-test extended to assert msl-vmm + Frameworks presence and
  codesign validity (`packaging/tests/`).

### G8.5 — Reproducibility & size audit
Record bundle size delta (dylibs + gpu-tools initramfs growth); budget:
≤ +150 MiB pkg. If KosmicKrisp/tools push past budget, feature-flag them
out of release (dev-only fetch).

## Exit criteria

- Clean-machine `make host-deps app` succeeds; CI green with new jobs;
  release pkg builds, signs, notarizes with msl-vmm inside.
- THIRD-PARTY-LICENSES complete; license audit note in PR.
- Size budget recorded.
