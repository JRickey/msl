# 06 — Milestone G1: VMBackend Abstraction

Goal: introduce the `VMBackend` protocol and route every VM consumer through
it, with the VZ implementation preserving bit-identical behavior. This is a
pure refactor; it can proceed in parallel with G0 and G2. All work is in
`host/Sources/MSLCore` + call sites; no guest changes.

## Entry criteria

None (independent of G0).

## Design

### G1 types (new file `host/Sources/MSLCore/VMBackend.swift`)

```swift
public enum VMBackendKind: String, Codable, Sendable { case vz, krun }

public enum BalloonKind: Sendable { case traditional, freePageReporting, none }

public struct VMBackendCapabilities: Sendable {
    public let kind: VMBackendKind
    public let rosetta: Bool
    public let gpu: Bool
    public let balloon: BalloonKind
}

/// Handler invoked for guest-initiated ("reverse") vsock connections.
/// Mirrors the current VZVirtioSocketListenerDelegate usage: receives a
/// dup'd fd it now owns, plus the port, on an arbitrary thread.
public protocol ReverseVsockHandler: AnyObject {
    func handleReverseConnection(fd: Int32, port: UInt32)
}

public protocol VMBackend: AnyObject {
    var capabilities: VMBackendCapabilities { get }
    var consolePath: String { get }
    func startAndWait(onStop: @escaping @Sendable (Error?, Bool) -> Void) throws
    func stopAndWait() throws
    func connectAndWait() throws -> VsockClient
    func connectRaw(port: UInt32, timeout: TimeInterval) throws -> Int32
    func setReverseListener(_ handler: ReverseVsockHandler, port: UInt32) throws
    func removeReverseListener(port: UInt32)
    func setMemoryTarget(mib: UInt64) throws
}
```

Notes:
- Method names may keep the current `VMHost` spellings where that reduces
  churn (`setBalloonTarget` → `setMemoryTarget` is the one rename; VZ maps it
  to the balloon, krun will map it to reclaim hints). Follow repo style.
- `rosettaAvailable()` stays a **static** VZ concern: move it to
  `VZBackend.rosettaHostAvailable()`; `DaemonCore.resolveRosettaShare()`
  consults capabilities + that static.
- `BootSpec` is unchanged in G1 except: add `backend: VMBackendKind = .vz`
  (defaulted, so all existing call sites compile) and keep `rosettaShare`
  validation independent of backend for now (G7 adds cross-validation).

### VZBackend

`VMMachine.swift`'s `VMHost` is renamed/wrapped:

- Option chosen: **`extension VMHost: VMBackend`** + a tiny
  `VMBackendFactory` — minimal diff, no file moves. `InteropListener` /
  `AuthBridgeListener` delegate conformances are already fd-shaped inside;
  refactor their VZ-specific `shouldAcceptNewConnection` plumbing so the
  business logic lives in `ReverseVsockHandler` conformances
  (`InteropListener`, `AuthBridgeListener` classes minus the `VZVirtioSocket*`
  types) and only a thin VZ adapter file still imports Virtualization.
- After G1, the *only* files importing Virtualization are `VMMachine.swift`,
  `VMMachine+Rosetta.swift`, and one new `VZReverseListenerAdapter.swift`.

### Factory and call sites

```swift
public enum VMBackendFactory {
    public static func make(spec: BootSpec) throws -> VMBackend
    // .vz → VMHost(spec:); .krun → KrunBackend(spec:) (G3; until then throws
    // MSLError.backendUnavailable)
}
```

Call sites to convert (from 01-current-architecture §1):
1. `DaemonCore` (`host` property type becomes `VMBackend?`;
   `performBoot()` uses the factory; `finishBoot`, `idleTick`, `handleStop`,
   memory ladder, `setInteropListener`/auth-bridge installs go through the
   protocol).
2. `Driver.swift` (both sites), `UpDriver`, `BootCommand` — direct-VM paths;
   these stay VZ-only by policy (add a guard: direct `msl boot` of the krun
   backend arrives with G3's `--backend` flag).
3. `InstallDriver`, `ExportDriver` — builder VM stays VZ forever (no GPU
   need; Rosetta-independent; churn-free). Convert to the protocol anyway so
   the type system is uniform.

## Work items

### G1.1 — Introduce protocol + capabilities + factory
Add `VMBackend.swift`; conform `VMHost`; add factory; no call-site changes
yet. Build + existing tests green.

### G1.2 — Reverse-listener refactor
Split `InteropListener.swift` / `AuthBridgeListener.swift` into
transport-free handler logic (`ReverseVsockHandler`) + VZ adapter. The VZ
adapter dups the fd exactly as today (`InteropListener.swift`
`shouldAcceptNewConnection`) and forwards. Unit-test the handler logic with a
socketpair (no VZ needed) — new tests in `MSLCoreTests`.

### G1.3 — Convert DaemonCore
Swap `host: VMHost?` → `VMBackend?`; route balloon via `setMemoryTarget`;
capabilities-gate the Rosetta share resolution. Acceptance: `make host sign
&& make smoke` passes; manual: install/shell/run/stop, GUI launch, FSKit
mount, Rosetta distro — all unchanged (spot-check on hardware; CI covers
build+unit only).

### G1.4 — Convert remaining call sites + guard rails
Driver/Up/Boot/Install/Export via factory. `msl boot` gains hidden
`--backend vz|krun` (krun → "not yet available" error until G3).

### G1.5 — Config plumbing (inert)
Add `gpu: Bool = false` to per-distro config model (wherever `rosetta` lives
today, e.g. registry/config JSON) + `msl config <distro> --gpu on|off`
parsing with validation stub: enabling gpu errors with "GPU backend not yet
available" (flag lands now so config-file format churn happens once).
Reject `--gpu on` + `--rosetta on` combination already.

## Exit criteria

- Only 3 files import Virtualization (VMMachine, +Rosetta, VZ adapter).
- `swift test` green; smoke target green; no behavior change on hardware
  spot-check.
- `msl config --gpu` exists (inert), validated against rosetta conflict.
- swiftlint/swift-format clean (CI strict).
