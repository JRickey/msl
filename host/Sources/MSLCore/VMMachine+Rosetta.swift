import Foundation
import Virtualization

/// Rosetta x86-64 translation support for the shared VM: availability detection
/// and the fixed-tag virtiofs device. The guest mounts tag "rosetta" and
/// registers the x86-64 ELF interpreter via binfmt_misc (docs/specs/rosetta-*).
extension VMHost {
    /// True when Rosetta is installed on the host. Detection only — installation
    /// is the user's action (softwareupdate --install-rosetta), never ours.
    public static func rosettaAvailable() -> Bool {
        return VZLinuxRosettaDirectoryShare.availability == .installed
    }

    /// Build the Rosetta virtiofs device (fixed tag "rosetta"). The caller has
    /// already gated on availability; a throwing init is wrapped as an MSLError.
    static func makeRosettaShare() throws -> VZVirtioFileSystemDeviceConfiguration {
        assert(ShareSpec.isValidTag("rosetta"), "fixed rosetta tag must satisfy the tag grammar")
        let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
        assert(VMHost.rosettaAvailable(), "caller must gate makeRosettaShare on availability")
        do {
            device.share = try VZLinuxRosettaDirectoryShare()
        } catch {
            throw MSLError.fromVZ("VZLinuxRosettaDirectoryShare", error)
        }
        return device
    }
}
