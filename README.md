<p align="center">
  <img src="assets/msl-hero-rounded.png" alt="msl running Ubuntu in a macOS Terminal window" width="100%">
</p>

# msl

msl is a WSL2-style Linux subsystem for MacOS, built in Swift and Rust,
for Apple Silicon.

## Author's Notes

The objective of this project is to provide the same feeling that WSL provides for Windows,
but on Mac. That is, the feeling of a seamless Linux Machine that lives within
your Mac: An instant Linux shell, named distros, localhost in Linux that also opens
on Mac, command interop between Mac and Linux, the ability to access your Linux
files in Finder, and a native GUI experience. GUI apps open in MacOS windows, 
work seamlessly with retina displays, virtual desktops, and minimizing to the
toolbar. Your Mac visual settings like dark mode carry through to Linux GUI apps.

This is not a generic VM manager.

I do not like using VMs. They are clunky, they feel disposable, easy to forget about
and lose work in, and most importantly, fake. msl obviously has to use virtualization
but provides a lot more UX features besides dropping a linux distro in a container.
I personally always prefer using an actual platform to do platform specific work
or testing. However, my work typically requires me to test my projects on Linux, 
or to use Linux specific utilities like GDB. I do not want to make a disposable VM 
or Apple Container for Linux. I like WSL's style and UX a lot, and wanted to bring that 
over to my Macbook, which is my preferred development platform.

msl is built around Apple's Virtualization.framework:

- A Swift host owns the CLI, resident daemon, VM lifecycle, AppKit/menu-bar UI,
  and FSKit integration.
- A static-musl Rust guest agent runs inside a shared utility VM and talks to
  the host over vsock.
- One msl kernel is shared by all distros; each distro is a containerized
  userland inside the VM.
- Guests are native arm64 by default. Rosetta x86-64 Linux translation is an
  explicit per-distro opt-in.

## Status

This repository is under active development.

Working:

- Boot a headless Linux VM with a Rust PID-1-adjacent agent.
- Run Ubuntu-style systemd distros as named containerized userlands.
- Use a resident per-user daemon with lazy shared-VM boot, idle shutdown, and
  faithful shell/command exit codes.
- Install, list, remove, configure, set default, export, and re-import distros.
- Share the Mac home directory into Linux at `/mnt/Mac`, with opt-out per
  distro.
- Mirror guest TCP listeners onto `127.0.0.1` on MacOS.
- Run Mac commands from Linux through the `Mac` shim.
- Transparently execute Mach-O binaries from Linux through binfmt.
- Export and install `.msl` distro bundles; double-click `.msl` install is
  handled by `msl.app`.
- Enable Rosetta per distro for x86-64 Linux binaries.
- Mount a distro in Finder at `~/msl/<distro>` through FSKit. Read-only mode is
  certified; the read-write protocol, guest worker, host FSKit surface, CLI
  mode, and write E2E harness have landed.
- Present Linux GUI windows through the `msl-way`/AppKit prototype path, with
  native windows, popups, resize pacing, and measured frame/input latency.

Planned next:

- Productize GUI app support beyond the prototype gate.
- Improve Mac file-sharing performance beyond Apple's virtiofs metadata limits.
- Add a Mac-native services layer: Keychain-backed Secret Service, XDG desktop
  portals, notifications, SSH agent bridging, trust/certificate sync, Touch ID
  for Linux authorization, and related Mac integration.
- Decide whether source builds need a zero-Apple-account Finder fallback for
  cases where the developer cannot sign a profile-backed FSKit appex.

Known constraints:

- MacOS 26+ on Apple Silicon is the target platform.
- The base VM is headless and NAT-only. Bridged networking requires an
  Apple-restricted entitlement and is not part of the current design.
- FSKit Finder integration requires the distributed app to include a signed
  app-extension with the `com.apple.developer.fskit.fsmodule` entitlement. Users
  of a properly signed/notarized release should not need their own Apple
  Developer account; source builders who want FSKit do.
- Virtualization.framework exposes no Linux GPU acceleration. GUI apps use
  software rendering; correct behavior is the goal before GPU-class speed.
- Rosetta is an escape hatch, not the primary path, and Apple's long-term
  Rosetta policy may force a future fallback.

## Requirements

Developer builds currently assume:

- Apple Silicon Mac running MacOS 26 or newer.
- Full Xcode with the MacOS 26 SDK and Swift 6.x toolchain.
- Rust with the `aarch64-unknown-Linux-musl` target.
- `cargo-zigbuild` and Zig for Linux-musl guest builds from MacOS.
- A checked-out `kernel/` submodule containing the msl kernel build recipe.
- Optional for FSKit appex work: `xcodegen`, an Apple Development signing
  identity, an App ID with File System Module and App Groups capabilities, and
  a provisioning profile for the local Mac.
- Optional for `msl-way`: Homebrew bison >= 3.8 and the static libxkbcommon
  build path used by `tools/mk-libxkbcommon.sh`.

The ordinary CLI/daemon path uses the standard virtualization entitlement and
can be ad-hoc signed for local development.

## Build

Initialize submodules first:

```sh
git submodule update --init --recursive
```

Common build targets:

```sh
make host              # Swift host release build
make sign              # ad-hoc sign the CLI with virtualization entitlement
make guest             # Rust guest workspace for aarch64-musl
make initramfs         # assemble build/initramfs.cpio
make builder-initramfs # assemble build/builder-initramfs.cpio
make app               # assemble build/msl.app
make smoke             # boot the minimal VM and run an exec smoke test
```

The guest uses `cargo zigbuild`, not plain `cargo build`, because MacOS does
not provide a Linux ELF linker, musl sysroot, or C cross-compiler.

SwiftPM does not re-sign products after rebuilds. Use `make host sign` or a
Makefile target that depends on signing before running a Virtualization-backed
binary.

## Quick Start

Build the CLI:

```sh
make host sign
```

Create or install a distro image. A `.msl` bundle can carry its own default
name:

```sh
host/.build/release/msl install ubuntu --from ./ubuntu-rootfs.tar.xz
host/.build/release/msl install --from ./ubuntu-custom.msl
```

Open a shell:

```sh
host/.build/release/msl shell ubuntu
```

Run a command:

```sh
host/.build/release/msl run ubuntu -- /usr/bin/uname -a
```

Check daemon and distro state:

```sh
host/.build/release/msl status
host/.build/release/msl list
```

Export a shareable bundle:

```sh
host/.build/release/msl export ubuntu --output ubuntu.msl
```

Enable Rosetta for a distro:

```sh
host/.build/release/msl config ubuntu --rosetta on
```

Mount a distro in Finder:

```sh
host/.build/release/msl fskit enable
host/.build/release/msl mount ubuntu --read-only --reveal
host/.build/release/msl unmount ubuntu
```

Read-write FSKit mounts are the default for `msl mount`, but live use requires a
profile-backed FSKit appex build.

## CLI Reference

Help is built in:

```sh
msl help
msl help run
msl help daemon install
```

User-facing commands:

| Command | Purpose |
| --- | --- |
| `msl install [name] --from <path>` | Install an ext4 image, rootfs tarball, or `.msl` bundle. |
| `msl list` | List installed distros with state, image size, and hostname. |
| `msl default <name>` | Set the default distro. |
| `msl config <name>` | Show or change hostname, default user, Mac sharing, and Rosetta. |
| `msl shell [name] [-- <argv...>]` | Open a daemon-backed shell. |
| `msl run [name] -- <command> [args...]` | Run one command and preserve its exit status. |
| `msl status` | Show daemon, VM, memory, forwarded ports, distro state, and sessions. |
| `msl stop [name]` | Stop one distro gracefully. |
| `msl stop --all` | Stop all distros and the shared VM; keep the daemon alive. |
| `msl shutdown` | Stop all distros, stop the VM, and exit the daemon. |
| `msl export <name>` | Export a distro to `.tar` or `.msl`. |
| `msl mount [name]` | Mount a distro at `~/msl/<distro>` through FSKit. |
| `msl unmount [name]` | Unmount a distro Finder view. |
| `msl fskit enable/status/disable` | Manage the MacOS FSKit enabled-modules setting. |
| `msl daemon run/install/uninstall` | Run or install the per-user daemon. |
| `msl up` | Direct boot path for registered or one-off rootfs images. |
| `msl boot` | Low-level developer VM boot command. |

There is also a hidden `msl gui-spike` command for the GUI forwarding prototype.

## Agent Skill

This repository includes a portable Agent Skills-compatible consumer skill at
`skills/msl/`. This is for your agents to learn how to use msl if you're working
on a project that benefits from the utility msl provides.

Install it into Codex with:

```sh
mkdir -p ~/.agents/skills
cp -R skills/msl ~/.agents/skills/msl
```

Install it into Claude Code with:

```sh
mkdir -p ~/.claude/skills
cp -R skills/msl ~/.claude/skills/msl
```

See `skills/README.md` for repo-scoped install paths and packaging notes.

## Architecture

### Host

The Swift package in `host/` contains:

- `msl`: command-line interface.
- `MSLCore`: VM lifecycle, daemon, registry, protocols, interop, port
  forwarding, FSKit mount lifecycle, GUI presenter support, and shared helpers.
- `MSLFSWire`: Swift FSKit file-service codec shared by the daemon and appex.
- `msl-menubar` and `MSLMenuBarCore`: menu-bar app and `.msl` open/install
  flow.
- `msl-fskit`: FSKit app extension source. SwiftPM type-checks it, but the
  shippable appex is built by Xcode through `host/fskit-appex.yml`.
- `msl-fskit-probe-server`: local signing/auth probe utility.

The daemon is a per-user LaunchAgent. It owns the shared VM, boots it lazily,
attaches registered distro images, brokers shell/run sessions, keeps active
mounts alive, mirrors guest ports to host localhost, and exposes Mac interop
surfaces.

### Guest

The Rust workspace in `guest/` contains:

- `msl-agent`: guest control plane and distro lifecycle manager.
- `msl-wire`: shared guest-side wire framing and FS protocol code.
- `msl-shim`: Linux-side `Mac` shim and transparent Mach-O exec helper.
- `msl-fsd`: FSKit file-service worker launched inside a distro namespace.
- `msl-way`: headless Wayland compositor and remoting prototype.

Guest crates use Rust edition 2024 and deny unsafe code. The production guest
artifacts are static-musl binaries.

### Kernel

`kernel/` is a submodule. The msl repository is Apache-2.0; the kernel source
recipe is GPLv2 in the kernel repo. Kernel source and msl source do not move
between repositories.

## Interop

Linux-to-Mac command interop uses a guest-initiated vsock channel. Interactive
and noninteractive stdio are framed separately, and exit codes propagate back to
Linux.

Inside a distro:

```sh
Mac sw_vers
Mac open .
```

Transparent Mach-O exec registers binfmt entries inside each distro, so a Mac
binary on `/mnt/Mac` can be invoked without the `Mac` prefix when the target is
safe to map back to the host.

## Filesystems

Mac home sharing uses virtiofs at `/mnt/Mac`. It is convenient and correct, but
metadata-heavy workloads are slower than guest ext4 because Apple's virtiofs
path serializes and compounds APFS create/delete costs. Keep build scratch and
large dependency trees on guest ext4 when performance matters.

Finder access to Linux files uses FSKit:

- `msl mount <distro>` mounts at `~/msl/<distro>`.
- `msl mount <distro> --read-only` keeps the certified EROFS path.
- `msl unmount <distro> --force` can clear a stranded mount if needed.

The FSKit path is architecturally preferred because msl owns both ends of the
protocol and can bound failure as `EIO`/`ENODEV`. The distribution challenge is
Apple's restricted FSKit entitlement; an NFS fallback remains the no-paid-account
design path.

## GUI Direction

GUI forwarding is built around a guest-terminated Wayland compositor
(`msl-way`) and a Swift AppKit/Metal host presenter. The host does not parse
Wayland; it receives an msl-owned window/surface protocol over vsock.

The prototype has demonstrated native windows, popups, resize handling, Retina
scale handling, host-driven pacing, and low input/present latency for software
rendered apps. GPU acceleration is not available through Virtualization.framework
today, so GL-heavy and Electron-style apps are expected to be correct before
they are fast.

## Validation

Common host checks:

```sh
swift test --package-path host
make host
make app
swift format lint --strict <changed-swift-files>
swiftlint lint --strict --quiet <changed-swift-files>
```

Common guest checks:

```sh
(cd guest && cargo fmt --check)
(cd guest && cargo test --workspace)
(cd guest && cargo clippy --all-targets --quiet -- -D warnings)
(cd guest && cargo clippy --target aarch64-unknown-Linux-musl --all-targets --quiet -- -D warnings)
(cd guest && cargo deny check)
make guest
make initramfs
```

FSKit live checks:

```sh
tools/fskit-e2e.sh
tools/fskit-e2e.sh --write
```

Those FSKit checks require a signed, enabled appex environment. If that state is
not available, run the build, unit, lint, and type-check gates that do not
depend on the MacOS extension runtime.

## Repository Layout

```text
.
├── entitlements/      # dev, release, and FSKit appex entitlements
├── guest/             # Rust guest workspace
├── host/              # SwiftPM host package
├── kernel/            # GPLv2 kernel source/build submodule
├── tools/             # initramfs/rootfs/FSKit/libxkb/license helpers
├── Makefile           # build, sign, app, smoke, and packaging targets
├── LICENSE            # Apache-2.0 for this repository
├── NOTICE             # attribution notices
└── THIRD-PARTY-LICENSES
```

The local development workflow may also use ignored working documents under
`docs/` for roadmap, ADRs, specs, reports, and research notes.

## License

msl is Apache-2.0. The kernel submodule is GPLv2 and is kept as a separate
source boundary. See `LICENSE`, `NOTICE`, `THIRD-PARTY-LICENSES`, and the kernel
submodule's `COPYING` file.
