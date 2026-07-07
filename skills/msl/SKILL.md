---
name: msl
description: Use msl, the macOS Subsystem for Linux, from another project. Trigger when a user wants Linux commands, packages, shells, build tools, tests, servers, or distro files on macOS via msl; when they mention msl, WSL-like Linux on Mac, /mnt/mac, .msl bundles, Rosetta, Finder mounts, or running project workflows inside Linux.
---

# msl Consumer Skill

Use this skill when helping a user consume msl from a different repository or
workflow. Do not assume you are developing msl itself. Treat msl as the user's
local Linux subsystem for macOS.

This skill is Apache-2.0 and intended for Codex, Claude Code, and other Agent
Skills-compatible harnesses. It assumes the user has msl installed on macOS
Apple Silicon.

## What msl is

msl is a WSL2-style Linux subsystem for macOS on Apple Silicon. It gives the
user named Linux distros, daemon-backed shells, command execution, catalog and
local-source installs, Mac/Linux interop, localhost forwarding, `.msl` distro
bundles, optional Rosetta x86-64 Linux translation, Finder access to Linux
files, and Mac app launchers for distros.

The normal user surface is the `msl` CLI:

- `msl help [topic...]` shows command help.
- `msl list` shows installed distros.
- `msl status` shows daemon, VM, memory, forwarded ports, distro state, and
  sessions.
- `msl shell [distro]` opens an interactive Linux shell.
- `msl run [distro] -- <command> [args...]` runs one Linux command with faithful
  exit status.
- `msl catalog list` and `msl catalog show <selector>` inspect catalog distros.
- `msl install <selector> [--name <name>]` installs a catalog distro.
- `msl install [name] --from <img|tar|tar.gz|tar.xz|msl>` installs from a local
  source.
- `msl export <name> --output <name>.msl` creates a portable distro bundle.
- `msl launcher list/create/remove/refresh/reveal/open` manages Mac app
  launchers under `/Applications/msl` by default.
- `msl desktop probe <distro>` and `msl desktop launch <distro>` check or launch
  supported desktop sessions.
- `msl mount [distro] [--read-only] [--reveal]` mounts the distro at
  `~/msl/<distro>` through Finder when FSKit is available.
- `msl config <distro> --rosetta on|off` controls x86-64 Linux translation.
- `msl stop`, `msl stop --all`, and `msl shutdown` stop distros or the daemon.

## First checks

When a task may need Linux through msl:

1. Check whether `msl` exists:
   ```sh
   command -v msl
   ```
2. Inspect available distros:
   ```sh
   msl list
   ```
3. Inspect runtime state:
   ```sh
   msl status
   ```
4. Use the default distro unless the user named one or `msl list` makes a
   better choice obvious.

If `msl` is missing, tell the user it is not installed or not on `PATH`. Do not
invent install instructions unless the repository or release notes in the
current task provide them.

If no distro is installed and the user wants one, prefer the catalog flow when
available:

```sh
msl catalog list
msl catalog show ubuntu
msl install ubuntu
```

Use `msl install <selector> --name <name>` to install a catalog distro under a
different local name. Use `msl install [name] --from <path>` only when the user
has a specific image, rootfs tarball, or `.msl` bundle.

## Running Linux commands

Prefer `msl run` for noninteractive work:

```sh
msl run -- /bin/sh -lc 'uname -a && pwd'
msl run ubuntu -- /bin/sh -lc 'sudo apt-get update'
```

Use an absolute executable path after `--` when possible. For compound commands,
use `/bin/sh -lc '...'` or the distro's shell.

Use `msl shell [distro]` only when the user specifically wants an interactive
session or when a tool truly needs a TTY.

Preserve the user's project directory. If the project is under the Mac home
directory and Mac sharing is enabled, it is usually reachable inside Linux under
`/mnt/mac/...`. Convert paths carefully:

- macOS: `/Users/alice/project`
- Linux through msl: `/mnt/mac/project` when the user's home is shared

If a path is not available under `/mnt/mac`, run commands in the distro's own
filesystem and copy or export results explicitly.

## Choosing Mac vs Linux

Use msl when the task needs Linux behavior:

- Linux-only packages or toolchains.
- `apt`, `dnf`, `apk`, systemd services, Linux shells, or GNU userland behavior.
- Linux CI parity for build/test commands.
- Native Linux path semantics, symlinks, permissions, or case-sensitive trees.
- Running a server or tool that should appear on macOS localhost through msl's
  port forwarding.

Stay on macOS when the task is purely host-side:

- Editing files.
- Running macOS-only tools, Xcode, codesign, Finder, or app bundles.
- Accessing macOS keychain, GUI automation, or host package managers.

For mixed workflows, edit on macOS and run Linux build/test commands through
`msl run` from the mapped `/mnt/mac` project path.

## Packages and project setup

Detect the distro before choosing package commands:

```sh
msl run -- /bin/sh -lc 'cat /etc/os-release'
```

Use the distro-native package manager. Ask before making broad or slow package
changes unless the user explicitly requested environment setup.

For repeatable project setup, prefer documenting the exact `msl run ...`
commands in the user's project README or scripts rather than making hidden
manual changes in an interactive shell.

## Servers and ports

msl mirrors guest TCP listeners to macOS `127.0.0.1` when the daemon is running.
For local web apps:

1. Start the server inside Linux with `msl run` or `msl shell`.
2. Bind to `127.0.0.1` or `0.0.0.0` inside Linux.
3. Check `msl status` for forwarded ports.
4. Tell the user the macOS URL, usually `http://127.0.0.1:<port>`.

If a port does not appear, verify the process is still listening inside Linux:

```sh
msl run -- /bin/sh -lc 'ss -ltnp'
```

## Mac/Linux interop

Inside Linux, users can run Mac commands through the `mac` shim:

```sh
mac open .
mac sw_vers
```

Transparent Mach-O execution works for Mac binaries reachable through the Mac
share when msl can safely map the path back to the host. For agent work, prefer
explicit `mac ...` commands when the intent is host-side.

## Rosetta

Rosetta is for x86-64 Linux binaries inside an arm64 distro. It is opt-in:

```sh
msl config <distro> --rosetta on
msl stop <distro>
msl run <distro> -- /bin/sh -lc 'uname -m'
```

Use Rosetta only when a required Linux binary is x86-64-only. Native arm64 Linux
packages should stay on the native path.

## Finder and file access

When FSKit is available:

```sh
msl fskit status
msl fskit enable
msl mount <distro> --read-only --reveal
msl unmount <distro>
```

Use read-only mounts for inspection and copying. Use read-write mounts only
when the user explicitly wants to edit Linux files from macOS and their msl
installation supports the signed FSKit extension.

If FSKit is unavailable, use `msl run` and `/mnt/mac` workflows instead of
assuming Finder mounting works.

## Distro app launchers

Installed distros can have Mac app launchers. Catalog and local-source installs
create msl-owned launchers by default. The default location is
`/Applications/msl`; development builds may override it with
`MSL_APPLICATIONS_DIR`.

Useful launcher commands:

```sh
msl launcher list
msl launcher create <distro> --mode shell
msl launcher create <distro> --mode auto --replace
msl launcher open <distro>
msl launcher reveal <distro>
msl launcher refresh <distro>
msl launcher remove <distro>
```

Use `shell` mode for reliable terminal-backed distro entry points. Use `auto`
or `desktop` mode only when a supported desktop session is installed and the GUI
bridge is expected to work:

```sh
msl desktop probe <distro>
msl desktop launch <distro>
```

## Safety and cleanup

- Do not stop or shut down msl while user work may be running.
- Prefer `msl stop <distro>` over `msl shutdown` unless the user asks to stop
  the daemon too.
- If a command may install many packages, modify system services, delete files,
  or change a distro's default config, explain the action first.
- Keep build artifacts where the user expects them: project artifacts under the
  project tree; Linux-only caches inside the distro.
- For performance-sensitive builds, keep dependency caches and scratch trees on
  Linux ext4 rather than `/mnt/mac`.

## Troubleshooting quick map

- `msl: command not found`: msl is not installed or not on `PATH`.
- `daemon not running`: `msl shell`, `msl run`, or `msl daemon run` can start it.
- No distro installed: try `msl catalog list`, then `msl install <selector>`; use
  `msl install [name] --from <path>` for user-provided images, tarballs, or
  `.msl` bundles.
- Command cannot find project files: check `/mnt/mac` mapping and `pwd` inside
  `msl run`.
- Linux server unreachable from macOS: check the guest listener with `ss -ltnp`
  and forwarded ports in `msl status`.
- Finder mount unavailable: check `msl fskit status`; FSKit requires a signed
  extension environment.
- Launcher missing or stale: run `msl launcher list`, then
  `msl launcher refresh <distro>`.
