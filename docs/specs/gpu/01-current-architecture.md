# 01 — Current Architecture (as-is)

This is the ground truth an implementer needs before touching anything. All
references verified against `main` @ `ff8382c`. Symbol names are authoritative
where line numbers have drifted.

## 1. Host: Virtualization.framework usage is confined to four files

Only these files `import Virtualization`:

1. `host/Sources/MSLCore/VMMachine.swift` — the single VM owner, class
   `VMHost` (final class, no protocol). Everything VZ funnels through here.
2. `host/Sources/MSLCore/VMMachine+Rosetta.swift` — `rosettaAvailable()`,
   `makeRosettaShare()` (`VZLinuxRosettaDirectoryShare` behind a virtiofs
   device tagged `rosetta`).
3. `host/Sources/MSLCore/InteropListener.swift` — reverse-vsock listener
   install/remove (`VZVirtioSocketListener` + delegate) for port 5010.
4. `host/Sources/MSLCore/AuthBridgeListener.swift` — same pattern, port 5040.

### VMHost public surface (the de-facto backend interface)

```
startAndWait(onStop:)            // build config, validate, boot; blocking
stopAndWait()                    // stop + release machine/delegate/image locks
connectAndWait() -> VsockClient  // control port 5000 convenience
connectRaw(port:timeout:) -> fd  // host-initiated vsock connect, returns dup'd fd
setBalloonTarget(mib:)           // VZVirtioTraditionalMemoryBalloonDevice
setInteropListener(_:port:) / removeInteropListener(port:)   // reverse vsock
consolePath                      // serial log path
rosettaAvailable() (static)      // VZLinuxRosettaDirectoryShare.availability
```

### Devices configured (`VMHost.makeConfiguration()`, `VMMachine.swift:194-216`)

| Device | VZ type | Notes |
|---|---|---|
| Boot | `VZLinuxBootLoader(kernelURL:)` + `initialRamdiskURL` + `commandLine` | direct kernel boot, default cmdline `console=hvc0` (`DaemonConfig.swift:20`) |
| Console | `VZVirtioConsoleDeviceSerialPortConfiguration` + file handle attachment | write-only log; `makeConsole()` `:286-303` |
| vsock | `VZVirtioSocketDeviceConfiguration` (exactly one) | all planes |
| Entropy | `VZVirtioEntropyDeviceConfiguration` | |
| Network | `VZVirtioNetworkDeviceConfiguration` + `VZNATNetworkDeviceAttachment` | NAT only; inbound via vsock forwarder, not NIC |
| Disks | `VZVirtioBlockDeviceConfiguration` + `VZDiskImageStorageDeviceAttachment` | ≤26; one per distro (`/dev/vda…`); flock via `ImageLock` |
| Shares | `VZVirtioFileSystemDeviceConfiguration(tag:)` + `VZSingleDirectoryShare` | tag `mac` = user home → guest `/mnt/mac` |
| Rosetta | virtiofs device tag `rosetta` + `VZLinuxRosettaDirectoryShare` | optional, per-distro opt-in (`DaemonCore+Rosetta.swift:15-27`) |
| Balloon | `VZVirtioTraditionalMemoryBalloonDeviceConfiguration` | gated on `spec.balloonEnabled` |

**There is no graphics device, no keyboard/pointer, no sound, no save/restore
anywhere.** `BootSpec` (`host/Sources/MSLCore/BootSpec.swift`) is the validated
value type carrying kernel/initramfs/cmdline/cpu/mem/console/disks/shares/
balloon/rosetta; built by `DaemonCore.makeBootSpec`
(`DaemonCore+Lifecycle.swift:335-348`).

### Who constructs VMHost (all must move to the abstraction in G1)

- `DaemonCore.performBoot()` (`DaemonCore+Lifecycle.swift:10-55`) — the daemon
  shared VM (lazy boot, idle stop at 60 s via `IdlePolicy`, 5 s tick, 2 s
  `net_listeners` poll, memory ladder + balloon).
- `Driver.swift:29/52`, `UpDriver` (`UpCommand.swift:78`), `BootCommand.swift:59`
  — direct-VM CLI paths.
- `InstallDriver.swift:252-255`, `ExportDriver.swift:159-162` — the in-process
  builder VM (Alpine builder initramfs; mkfs/tar inside the VM).

### Daemon control plane

Per-user LaunchAgent `dev.msl.daemon` (`LaunchAgent.swift`); Unix-socket JSON
protocol (`DaemonServer.swift`, `LocalRequest`/`LocalReply`, thread per
connection). Two requests upgrade to raw byte relays: `.attach` (PTY) and
`.guiAttach` (GUI plane). fd transport between daemon and guest is
`ByteRelay` splicing (no SCM_RIGHTS except presenter attach-token via
inherited pipe fd 3, `GuiPresenterLauncher.swift:13`).

### vsock port map (single `VZVirtioSocketDevice`)

| Port | Direction | Purpose | Framing |
|---|---|---|---|
| 5000 | host→guest | agent control (`Proto.version = 5`) | 4-byte BE length + JSON, 4 MiB cap |
| 5001 | host→guest | PTY data plane | handshake JSON then raw bytes |
| 5002 | host→guest | log stream | |
| 5003 | host→guest | TCP port-forward data | `ForwardHello` then raw splice |
| 5010 | guest→host | `mac` interop exec | reverse listener |
| 5020 | host→guest | **GUI surface plane (msl-way listens)** | 16-byte header framing (below) |
| 5030 | host→guest | FSKit file service (`FSProto` v2) | |
| 5040 | guest→host | auth bridge (ssh-agent/Keychain) | reverse listener |

## 2. Guest: agent and distro model

- `msl-agent` is PID 1 of the shared initramfs (`guest/agent/src/main.rs`),
  static musl Rust. Mounts pseudo-fs + virtiofs shares (`mac`, `staging`,
  `rosetta`), then serves vsock (`server.rs:19-23`).
- Distros = containerized userlands: raw `clone(2)` with
  `CLONE_NEWPID|CLONE_NEWNS|CLONE_NEWUTS|CLONE_NEWIPC` (**no** `CLONE_NEWNET`,
  **no** `CLONE_NEWUSER` — `sys.rs:507-527`, comment at `sys.rs:390-392`),
  mount distro ext4 from `/dev/vdX`, switch_root-style pivot, exec systemd.
  Up to 16 concurrent distros in the one VM. Command entry via `setns`.
- **Tool projection (ADR 0008):** initramfs `/tools` is bind-mounted into every
  distro at `/run/msl/tools` (`distro.rs:516-518, 933-943`). This is how
  `msl-way`, `mac`, `msl-fsd` etc. appear inside distros without touching
  distro images. **Ship guest Mesa the same way (G4).**
- GUI runtimes: lazily started per `(distro, linux-user)`, max 8 runtimes,
  64 windows each (`gui.rs:16-19`). `msl-way` launched from
  `/run/msl/tools/msl-way` with `WAYLAND_DISPLAY=msl-way-0`,
  `XDG_RUNTIME_DIR=/run/user/<uid>`; app env from `gui_env()`
  (`gui.rs:552-574`): `DISPLAY=:0`, `GDK_BACKEND=wayland,x11`,
  `QT_QPA_PLATFORM=wayland;xcb`, `SDL_VIDEODRIVER=wayland,x11`,
  `CLUTTER_BACKEND=wayland`, `LIBGL_ALWAYS_SOFTWARE=1`,
  `MESA_LOADER_DRIVER_OVERRIDE=llvmpipe`. Host mirror of that env:
  `GuiRuntime.swift:20-28`, asserted by `GuiRuntimeTests.swift:11` — the two
  lists must stay in sync.

## 3. GUI pipeline (protocol v5)

```
client wl_shm buffer
  └─ msl-way (Smithay 0.7 headless compositor; wl_shm ONLY, no dmabuf global)
       read_full_buffer() CPU copy (frames.rs:644-675) → CSD crop → damage pack
       encode_commit (remote.rs:465-510)
  └─ vsock 5020 (guest listens; host connects: bind_vsock remote.rs:1305-1335)
  └─ daemon ByteRelay (DaemonServer.handleGuiAttach)
  └─ msl-presenter (posix_spawned; GuiChannel blocking socket, 64-slot write window)
       GuiPresenter reader thread → keep-latest per window
  └─ GuiWindow (NSWindow/NSPanel per toplevel)
       GuiSurface: BGRA IOSurface, memcpy damage rects (GuiSurface.swift:29-51)
       GuiSurfacePool: triple buffer
       CADisplayLink step() → CALayer.contents = IOSurface (GuiWindow.swift:326-360)
       present_ack {win, seq, t_recv_ns, t_present_ns} back to guest
```

Protocol facts that matter for extension (G5):

- Framing: 16-byte LE header `{u32 type, u32 flags, u64 payload_len}`;
  `MAX_FRAME` 64 MiB (`remote.rs:96-161`, `GuiProto.swift:56-85`).
- `PROTOCOL_VERSION = 5` in `remote.rs:11` and `GuiProto.swift:14`; **hard
  version gate on both sides** (`main.rs:201-229`,
  `GuiPresenter.handleHello`). `HelloAck` already demonstrates the
  backwards-compatible optional-field pattern (`output_w/h`,
  `remote.rs:249-253`) — capability negotiation goes there, not a version bump.
- Commit payload: 56-byte prefix
  `{win, seq, w, h, stride, format, scale_e12, n_rects, serial, reserved,
  t_client_commit_ns, t_send_ns}` + rects + row-packed pixels. `format` is
  0 (XRGB8888) or 1 (ARGB8888); host rejects `format > 1`
  (`GuiProto.swift:250`). The `flags` header lane is always 0 today. Unknown
  message types are tolerated on both sides (`HostMsg::Unknown`;
  `GuiPresenter.handleFrame` default arm).
- Pacing: one un-acked present in flight; guest 50 ms starvation deadline
  (`frames.rs:108-211`); host `GuiPacer` + CADisplayLink.
- Xwayland: in-process rootless (`main.rs:535-570`, `xwm.rs`); X11
  override-redirect → host popups; else toplevels with X11 identity.
- HiDPI: host advertises `scale`/`refresh_hz` in `HelloAck`; guest pushes
  `wp_fractional_scale_v1` preferred scale; per-commit `scale_e12` (×4096).
- Latency harness exists on both sides (`GuiLedger` CSV p50/p95 in
  `GuiPacing.swift:122-198`; guest `ledger.rs` + `T_STATS`). **Reuse for all
  GPU-path acceptance measurements.**
- Dormant-but-specified protocol ranges: clipboard (types 25/26/33–36),
  cursor image (29), text input (27/28) — defined, not wired. Do not collide
  with them; new GPU types start at 40 (G5).

## 4. Kernel and build system

- `kernel/` is a git submodule → `github.com/JRickey/msl-kernel` (GPLv2 side of
  the license split). Today it only implements `make fetch`: downloads the
  **Kata Containers 3.17.0 static release** and extracts
  `vmlinux-6.12.28-153` as a flat arm64 `Image` (sha-pinned). `make build`
  (self-build with config + `patches/`) is an **unimplemented stub** that
  points at this docs tree. There is **no kernel config in either repo**, and
  the sibling apple/containerization kernel config (same Kata lineage) has
  `# CONFIG_DRM_VIRTIO_GPU is not set` — assume the fetched kernel cannot do
  virtio-gpu until proven otherwise (G2 verifies, then self-builds).
- Initramfs: `tools/mk-initramfs.sh` → `build/initramfs.cpio`; `/init` =
  `msl-agent`; `/tools/{mac,msl-fsd,msl-session,msl-ssh-agent,msl-secretsd,
  msl-way*}` (+busybox sh/echo/cat/uname). `REQUIRE_MSL_WAY=1` for release
  (`Makefile` `release-runtime`).
- Cross-build pattern to copy for Mesa: `tools/mk-libxkbcommon.sh` builds
  static libxkbcommon 1.7.0 with meson + ninja + `zig cc -target
  aarch64-linux-musl`; output linked into `msl-way` via
  `RUSTFLAGS -L native=guest/target/xkb-musl` (`Makefile:111-125`).
- Guest builds: `cargo zigbuild --target aarch64-unknown-linux-musl`.
- Runtime layout: `~/.msl/{kernel,initramfs.cpio,distros/<name>.img,…}` with
  fallback to `msl.app/Contents/Resources/*` (`MSLHome.swift`); assets copied
  into the bundle by the `app` target (`Makefile:147-201`).
- Entitlements: `com.apple.security.virtualization` everywhere VZ runs
  (`entitlements/*.entitlements`); FSKit appex sandboxed, no virtualization.
  The krun backend additionally needs `com.apple.security.hypervisor` (G3/G8).
- CI (`.github/workflows/ci.yml`): macos-26; swift build/test,
  swift-format/swiftlint strict, cargo fmt/clippy/test/deny, packaging test,
  `make guest initramfs app`. No VM boot in CI. Release (`release.yml`): tags,
  Developer ID signing, notarization, draft release.

## 5. What must NOT regress

- Faithful exit codes through daemon sessions (PTY plane 5001).
- Port mirroring (vsock 5003 + 2 s poll).
- `/mnt/mac` share and `mac` interop (5010 reverse + binfmt argv translation).
- FSKit mounts (5030 + app-group unix socket + appex).
- Rosetta distros (VZ-only feature; placement policy in G7 keeps them on VZ).
- SHM GUI path for non-GPU distros and as universal fallback.
- Idle shutdown / lazy boot semantics; `.msl` export/import; builder VM flows.
