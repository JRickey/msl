import Darwin
import FSKit
import Foundation

/// Unary FSKit delegate for the `mslfs` file system. Unit 0 proves the appex is
/// reachable through `mount -F` and can drive the app-group UDS probe; it does
/// not mount a volume, so `loadResource` returns a controlled `ENODEV`.
final class MSLFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private static let fallbackAppGroup = "group.dev.msl.app"
    private static let fallbackAppexID = "dev.msl.app.fsmodule"

    func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let generic = resource as? FSGenericURLResource else {
            reply(FSProbeResult.notRecognized, nil)
            return
        }
        guard let parsed = MSLResourceURL.parse(generic.url) else {
            reply(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        MSLFSKitLog.volume.info("probe recognized distro=\(parsed.distro, privacy: .public)")
        let containerID = FSContainerIdentifier(uuid: UUID())
        reply(FSProbeResult.usable(name: "mslfs", containerID: containerID), nil)
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        guard let generic = resource as? FSGenericURLResource,
            let parsed = MSLResourceURL.parse(generic.url)
        else {
            reply(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        let outcome = ProbeClient.run(
            appGroup: Self.appGroup(), resource: parsed, appexID: Self.appexID())
        logProbe(outcome, distro: parsed.distro)
        containerStatus = FSContainerStatus.notReady(status: fs_errorForPOSIXError(ENODEV))
        reply(nil, fs_errorForPOSIXError(ENODEV))
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        MSLFSKitLog.volume.info("unloadResource")
        containerStatus = FSContainerStatus.notReady(status: fs_errorForPOSIXError(ENODEV))
        reply(nil)
    }

    private func logProbe(_ outcome: ProbeOutcome, distro: String) {
        assert(!distro.isEmpty, "distro must be non-empty for logging")
        if outcome.connected {
            MSLFSKitLog.probe.info(
                "UDS probe ok distro=\(distro, privacy: .public) reply=\(outcome.reply, privacy: .public)"
            )
        } else {
            MSLFSKitLog.probe.error(
                "UDS probe failed distro=\(distro, privacy: .public) detail=\(outcome.detail, privacy: .public)"
            )
        }
    }

    /// App group from the appex `Info.plist` (`MSLAppGroup`), else the default.
    private static func appGroup() -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: "MSLAppGroup") as? String
        guard let group = value, !group.isEmpty else { return fallbackAppGroup }
        return group
    }

    private static func appexID() -> String {
        let value = Bundle.main.bundleIdentifier
        guard let identifier = value, !identifier.isEmpty else { return fallbackAppexID }
        return identifier
    }
}
