import Darwin
import FSKit
import Foundation
import MSLFSWire

/// Unary FSKit delegate for the `mslfs` file system. `probeResource` recognizes
/// the msl-scheme resource URL; `loadResource` connects the app-group channel to
/// the daemon and returns a read-only `MSLVolume`.
final class MSLFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
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
        reply(FSProbeResult.usable(name: FSProto.shortName, containerID: containerID), nil)
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
        let client = FSClient()
        do {
            try client.connect(distro: parsed.distro, mountID: parsed.mount, nonce: parsed.nonce)
            containerStatus = FSContainerStatus.active
            MSLFSKitLog.volume.info("loadResource ready distro=\(parsed.distro, privacy: .public)")
            reply(MSLVolume(client: client, distro: parsed.distro), nil)
        } catch {
            let mapped = Self.loadError(error)
            containerStatus = FSContainerStatus.notReady(status: mapped as NSError)
            MSLFSKitLog.volume.error(
                "loadResource failed distro=\(parsed.distro, privacy: .public)")
            reply(nil, mapped)
        }
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

    private static func loadError(_ error: any Error) -> any Error {
        if let posix = error as? FSProto.PosixError {
            return fs_errorForPOSIXError(posix.errno == 0 ? ENODEV : posix.errno)
        }
        return fs_errorForPOSIXError(ENODEV)
    }
}
