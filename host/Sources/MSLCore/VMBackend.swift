import Foundation

/// Backend-abstraction seam introduced in milestone G1
/// (`docs/specs/gpu/06-milestone-g1-backend-abstraction.md`). Every VM consumer
/// is meant to talk to `VMBackend` rather than the concrete `VMHost`, so a
/// second backend (krun, milestone G3) can slot in without touching call sites.
/// The VZ implementation (`VMHost`) preserves bit-identical behavior; this file
/// imports Foundation only, keeping Virtualization confined to the VZ pieces.

/// Which backend implements a VM. `krun` is reserved for milestone G3 and is
/// not constructible yet (`VMBackendFactory.make` throws for it).
public enum VMBackendKind: String, Codable, Sendable { case vz, krun }

/// How a backend reclaims guest memory. VZ drives a traditional balloon; other
/// backends may report free pages or offer no reclaim at all.
public enum BalloonKind: Sendable { case traditional, freePageReporting, none }

/// Static feature surface of a backend, consulted before wiring optional
/// devices (Rosetta share, GPU, memory reclaim) so call sites gate on
/// capabilities instead of backend-kind switches.
public struct VMBackendCapabilities: Sendable {
    /// The backend kind these capabilities describe.
    public let kind: VMBackendKind
    /// Whether the backend can attach the Rosetta share. Host installation of
    /// Rosetta is still checked separately (a capable backend on a machine
    /// without Rosetta installed still cannot attach it).
    public let rosetta: Bool
    /// Whether the backend can expose a GPU to the guest.
    public let gpu: Bool
    /// How, if at all, the backend reclaims guest memory.
    public let balloon: BalloonKind

    public init(kind: VMBackendKind, rosetta: Bool, gpu: Bool, balloon: BalloonKind) {
        self.kind = kind
        self.rosetta = rosetta
        self.gpu = gpu
        self.balloon = balloon
    }
}

/// Handler for guest-initiated ("reverse") vsock connections. Mirrors the VZ
/// delegate contract without exposing Virtualization types, so the business
/// logic (interop, auth bridge) is transport-free and unit-testable over a
/// socketpair. A backend-specific adapter owns the transport and forwards here.
public protocol ReverseVsockHandler: AnyObject, Sendable {
    /// Called on the VM queue and must return fast. Receives a dup'd blocking fd
    /// the handler now owns: close it on reject or when done. The return value is
    /// the accept/reject answer surfaced to the guest.
    func handleReverseConnection(fd: Int32, port: UInt32) -> Bool
    /// Invoked when the transport could not produce a usable fd (for example a
    /// failed `dup`). Has a default no-op implementation.
    func handleReverseAcceptFailure(errno code: Int32, port: UInt32)
}

extension ReverseVsockHandler {
    /// Default: most handlers only log; the failure hook is optional.
    public func handleReverseAcceptFailure(errno code: Int32, port: UInt32) {}
}

/// The de-facto VM interface every consumer routes through. Signatures match
/// `VMHost`'s real surface so its conformance is trivial (see `VMMachine.swift`
/// and `InteropListener.swift`).
public protocol VMBackend: AnyObject, Sendable {
    /// Static feature surface used to gate optional devices.
    var capabilities: VMBackendCapabilities { get }
    /// Path of the console-log file, once the VM has resolved one.
    var consolePath: String? { get }
    /// Build the VM, start it, and block until start succeeds or fails.
    func startAndWait(onStop: @escaping @Sendable (Error?, Bool) -> Void) throws
    /// Force-stop the VM and block; returns the stop error, `nil` on success.
    func stopAndWait() -> Error?
    /// Poll-connect to the control port, returning a framed client.
    func connectAndWait() throws -> VsockClient
    /// Poll-connect to `port`, returning an owned blocking fd.
    func connectRaw(port: UInt32, timeout: Double) throws -> Int32
    /// Install `handler` as the reverse listener for `port`. False on no VM.
    @discardableResult func setReverseListener(_ handler: any ReverseVsockHandler, port: UInt32)
        -> Bool
    /// Remove the reverse listener for `port`.
    func removeReverseListener(port: UInt32)
    /// Set the memory reclaim target to `mib` MiB. False when unsupported/stopped.
    @discardableResult func setMemoryTarget(mib: UInt64) -> Bool
}

/// Builds a backend from a `BootSpec`. `.vz` is the shipping implementation;
/// `.krun` is reserved for milestone G3 and throws until then.
public enum VMBackendFactory {
    public static func make(spec: BootSpec) throws -> any VMBackend {
        switch spec.backend {
        case .vz:
            return VMHost(spec: spec)
        case .krun:
            throw MSLError.configuration(
                "krun backend is not available yet (docs/specs/gpu, milestone G3)")
        }
    }
}
