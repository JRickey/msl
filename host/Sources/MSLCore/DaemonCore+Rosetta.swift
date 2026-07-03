import Foundation

/// Per-distro boot settings resolved from one registry load.
struct DistroBootSettings {
    let hostname: String
    let macShare: Bool
    let rosetta: Bool
}

/// Rosetta gating for the daemon: decide whether to attach the shared VM's
/// Rosetta virtiofs device this boot (docs/specs/rosetta-host.md).
extension DaemonCore {
    /// Attach the Rosetta share this boot when some distro opted in AND the host
    /// has Rosetta installed. Warns (and returns false) on opt-in without it.
    func resolveRosettaShare() throws -> Bool {
        let registry = try Registry.load(from: config.home.registryURL)
        let wanted = registry.distros.contains { $0.rosetta == true }
        guard wanted else { return false }
        guard VMHost.rosettaAvailable() else {
            log(
                "rosetta requested but not installed; run "
                    + "'softwareupdate --install-rosetta' — booting without it")
            return false
        }
        return true
    }
}
