import Foundation

/// One registered distro attached to the VM: its name, backing image path, and
/// the guest block device (`/dev/vda`, `/dev/vdb`, ...) it maps to.
public struct DeviceEntry: Sendable, Equatable {
    public let name: String
    public let dev: String
    public let imagePath: String
}

/// The result of planning which registered images become which guest devices.
public struct DeviceMapping: Sendable, Equatable {
    public let entries: [DeviceEntry]
    public let skipped: [String]

    public var diskPaths: [String] { entries.map { $0.imagePath } }
}

/// Plans the name-sorted image -> `/dev/vd?` mapping the daemon attaches at boot.
public enum DeviceMap {
    /// Sort `names`, drop any whose image is unreadable (recorded in `skipped`),
    /// and assign the survivors `/dev/vda`, `/dev/vdb`, ... in order (max 26).
    public static func compute(
        names: [String], imagePath: (String) -> String, isReadable: (String) -> Bool
    ) -> DeviceMapping {
        precondition(names.count == Set(names).count, "distro names must be unique")
        var entries: [DeviceEntry] = []
        var skipped: [String] = []
        for name in names.sorted() {  // bounded: registry list
            let path = imagePath(name)
            guard isReadable(path), entries.count < 26 else {
                skipped.append(name)
                continue
            }
            let letter = Character(Unicode.Scalar(UInt8(97 + entries.count)))
            entries.append(DeviceEntry(name: name, dev: "/dev/vd\(letter)", imagePath: path))
        }
        return DeviceMapping(entries: entries, skipped: skipped)
    }
}
