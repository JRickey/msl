import Foundation
import MSLFSWire

/// Mountpoint policy and resource-URL construction for the Finder view. Mounts
/// live under `~/msl/<distro>`; the resource URL carries only routing data.
public enum FSMountpoint {
    /// User-facing mount base (`~/msl`), the aggregated `\\wsl$` analog.
    public static func base(home: String = NSHomeDirectory()) -> String {
        precondition(!home.isEmpty, "home directory must not be empty")
        return URL(fileURLWithPath: home).appendingPathComponent("msl").path
    }

    /// `~/msl/<distro>` for a valid distro name; nil for an unsafe name.
    public static func directory(distro: String, home: String = NSHomeDirectory()) -> String? {
        guard isValidDistroName(distro) else { return nil }
        let path = URL(fileURLWithPath: base(home: home)).appendingPathComponent(distro).path
        assert(path.hasPrefix(base(home: home)), "mountpoint must stay under the base")
        return path
    }

    /// A distro name usable as a single path component and URL host: non-empty,
    /// bounded, and free of `/`, NUL, and `.`/`..` traversal.
    public static func isValidDistroName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\u{0}") else { return false }
        return true
    }

    /// Validate a client-supplied mountpoint: it must be exactly `~/msl/<name>`
    /// for the named distro, blocking traversal and mounts outside the base.
    public static func validate(
        mountpoint: String, distro: String, home: String = NSHomeDirectory()
    ) -> Bool {
        guard !mountpoint.isEmpty else { return false }
        guard let expected = directory(distro: distro, home: home) else { return false }
        return standardized(mountpoint) == expected
    }

    /// `msl://<percent-encoded-distro>?mount=<id>&nonce=<single-use>`.
    public static func resourceURL(distro: String, mountID: String, nonce: String) -> String? {
        guard isValidDistroName(distro), !mountID.isEmpty, !nonce.isEmpty else { return nil }
        var comps = URLComponents()
        comps.scheme = FSProto.scheme
        comps.host = distro
        comps.queryItems = [
            URLQueryItem(name: "mount", value: mountID),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        guard let url = comps.url?.absoluteString else { return nil }
        assert(url.hasPrefix("msl://"), "resource URL must use the msl scheme")
        return url
    }

    private static func standardized(_ path: String) -> String {
        assert(!path.isEmpty, "path must not be empty")
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
