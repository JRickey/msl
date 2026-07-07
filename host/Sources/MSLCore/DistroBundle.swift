import Darwin
import Foundation

/// Sniff a root tarball's compression from its leading bytes, so a `.msl`
/// bundle (which hides the real suffix) is classified by content, not name.
public enum BundleSniff {
    private static let gzipMagic: [UInt8] = [0x1F, 0x8B]
    private static let xzMagic: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
    private static let ustarMagic: [UInt8] = [0x75, 0x73, 0x74, 0x61, 0x72]
    private static let ustarOffset = 257

    /// gzip `1F 8B`; xz `FD 37 7A 58 5A 00`; else `ustar` at offset 257 →
    /// `.none`. Data too short for a check fails that check; no match → nil.
    public static func compression(header: Data) -> TarCompression? {
        let bytes = [UInt8](header)
        assert(bytes.count == header.count, "byte copy must preserve length")
        if hasMagic(bytes, gzipMagic, at: 0) { return .gzip }
        if hasMagic(bytes, xzMagic, at: 0) { return .xz }
        if hasMagic(bytes, ustarMagic, at: ustarOffset) { return TarCompression.none }
        return nil
    }

    private static func hasMagic(_ bytes: [UInt8], _ magic: [UInt8], at offset: Int) -> Bool {
        assert(!magic.isEmpty, "magic must not be empty")
        assert(offset >= 0, "offset must not be negative")
        guard bytes.count >= offset + magic.count else { return false }
        return Array(bytes[offset..<offset + magic.count]) == magic
    }
}

/// Parsed bundle metadata; all-nil is valid (a bundle without a conf member).
public struct BundleMeta: Sendable, Equatable {
    public let name: String?
    public let defaultUser: String?

    public init(name: String?, defaultUser: String?) {
        self.name = name
        self.defaultUser = defaultUser
    }

    private static let maxLines = 4096

    /// Parse the INI subset: `[section]` headers, `key = value`, `#`/`;`
    /// comments, blank lines. Only `[distro]` name/default-user are read;
    /// unknown sections/keys are ignored and the last duplicate wins. A value
    /// failing its grammar throws `invalidArgument` naming the key; over the
    /// line cap throws.
    public static func parse(conf: String) throws -> BundleMeta {
        let lines = conf.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= maxLines else {
            throw MSLError.invalidArgument("bundle conf exceeds \(maxLines) lines")
        }
        assert(lines.count <= maxLines, "line count bounded before the loop")
        var section = ""
        var name: String?
        var user: String?
        for raw in lines {  // bounded: ≤ maxLines
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard section == "distro", let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "name" {
                name = try validated(value, isValid: Registry.isValidName, key: "name")
            } else if key == "default-user" {
                user = try validated(value, isValid: Registry.isValidUser, key: "default-user")
            }
        }
        return BundleMeta(name: name, defaultUser: user)
    }

    private static func validated(
        _ value: String, isValid: (String) -> Bool, key: String
    ) throws -> String {
        assert(!key.isEmpty, "key label must not be empty")
        guard isValid(value) else {
            throw MSLError.invalidArgument("invalid \(key) in bundle conf: \(value)")
        }
        return value
    }

    /// Parse a WSL `wsl-distribution.conf`: only `[oobe]`'s `defaultName` is
    /// read, folded to the msl name grammar. Foreign metadata is advisory, so a
    /// name that fails the grammar reads as absent rather than throwing.
    public static func parseWSL(conf: String) throws -> BundleMeta {
        let lines = conf.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= maxLines else {
            throw MSLError.invalidArgument("bundle conf exceeds \(maxLines) lines")
        }
        var section = ""
        var name: String?
        for raw in lines {  // bounded: ≤ maxLines
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard section == "oobe", let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "defaultName" {
                let folded = value.lowercased()
                name = Registry.isValidName(folded) ? folded : nil
            }
        }
        return BundleMeta(name: name, defaultUser: nil)
    }

    /// Render a conf for export: `[distro]` with `name`, then `default-user`
    /// when non-nil. Trailing newline; `parse` round-trips the result.
    public static func render(name: String, defaultUser: String?) -> String {
        assert(Registry.isValidName(name), "name must be valid to render")
        var out = "[distro]\nname = \(name)\n"
        if let user = defaultUser {
            assert(Registry.isValidUser(user), "default-user must be valid to render")
            out += "default-user = \(user)\n"
        }
        return out
    }
}

/// A bundle's sniffed compression and parsed metadata.
public struct BundleInfo: Sendable, Equatable {
    public let compression: TarCompression
    public let meta: BundleMeta

    public init(compression: TarCompression, meta: BundleMeta) {
        self.compression = compression
        self.meta = meta
    }
}

/// Read a `.msl` bundle host-side: sniff the header, then extract the optional
/// conf member with `/usr/bin/tar` (bsdtar decompresses transparently).
public enum BundleReader {
    private static let confMembers = ["./etc/msl-distribution.conf", "etc/msl-distribution.conf"]
    private static let wslConfMembers = [
        "./etc/wsl-distribution.conf", "etc/wsl-distribution.conf",
    ]
    private static let stdoutCap = 1024 * 1024
    private static let deadlineSeconds = 300.0
    private static let maxReadIterations = 1 << 20
    private static let killGracePolls = 50
    private static let killGracePollUsec: useconds_t = 100_000

    /// Sniff ≤512 header bytes (unreadable or no magic → `invalidArgument`
    /// "not a tar archive"), then try the conf member under `./etc/` and
    /// `etc/`. Neither present → empty metadata. A present member is parsed as
    /// UTF-8 (invalid UTF-8 throws).
    public static func read(path: String) throws -> BundleInfo {
        assert(!path.isEmpty, "path must not be empty")
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw MSLError.invalidArgument("not a tar archive (unreadable): \(path)")
        }
        let compression = try sniff(path: path)
        for member in confMembers {  // bounded: two candidate paths
            guard let data = try extractMember(path: path, member: member) else { continue }
            guard let conf = String(data: data, encoding: .utf8) else {
                throw MSLError.invalidArgument("bundle conf is not valid UTF-8: \(path)")
            }
            let meta = try BundleMeta.parse(conf: conf)
            return BundleInfo(compression: compression, meta: meta)
        }
        for member in wslConfMembers {  // bounded: two candidate paths
            guard let data = try extractMember(path: path, member: member) else { continue }
            guard let conf = String(data: data, encoding: .utf8) else {
                throw MSLError.invalidArgument("bundle conf is not valid UTF-8: \(path)")
            }
            let meta = try BundleMeta.parseWSL(conf: conf)
            return BundleInfo(compression: compression, meta: meta)
        }
        return BundleInfo(compression: compression, meta: BundleMeta(name: nil, defaultUser: nil))
    }

    private static func sniff(path: String) throws -> TarCompression {
        assert(!path.isEmpty, "path must not be empty")
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw MSLError.invalidArgument("not a tar archive (unreadable): \(path)")
        }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 512)
        guard let compression = BundleSniff.compression(header: header) else {
            throw MSLError.invalidArgument("not a tar archive: \(path)")
        }
        return compression
    }

    /// Run `tar -xOf <path> <member>`, capturing stdout under the byte cap and
    /// deadline. A nonzero exit (absent member) returns nil; the caps and an
    /// unreadable UTF-8 stream throw. Stderr is discarded.
    private static func extractMember(path: String, member: String) throws -> Data? {
        assert(!path.isEmpty, "path must not be empty")
        assert(!member.isEmpty, "member must not be empty")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xOf", path, member]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw MSLError.io("cannot run /usr/bin/tar: \(error)")
        }
        let start = Date()
        armDeadline(process)
        let captured = try drain(outPipe.fileHandleForReading, process: process, path: path)
        process.waitUntilExit()
        guard Date().timeIntervalSince(start) < deadlineSeconds else {
            throw MSLError.timedOut("tar extract exceeded \(Int(deadlineSeconds))s: \(path)")
        }
        guard process.terminationStatus == 0 else { return nil }
        return captured
    }

    private static func armDeadline(_ process: Process) {
        assert(deadlineSeconds > 0, "deadline must be positive")
        let watchdog = DispatchQueue(label: "msl.bundle.tar.watchdog")
        watchdog.asyncAfter(deadline: .now() + deadlineSeconds) {
            hardStop(process)
        }
    }

    /// SIGTERM a runaway tar, escalating to SIGKILL if it ignores the term
    /// within a bounded grace window. A no-op on an already-exited process.
    private static func hardStop(_ process: Process) {
        guard process.isRunning else { return }
        assert(killGracePolls > 0, "grace window must allow at least one poll")
        assert(process.processIdentifier > 0, "a running process has a pid")
        process.terminate()
        var polls = 0
        while polls < killGracePolls {  // bounded: fixed grace window
            if !process.isRunning { return }
            usleep(killGracePollUsec)
            polls += 1
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }

    private static func drain(_ handle: FileHandle, process: Process, path: String) throws -> Data {
        assert(!path.isEmpty, "path must not be empty")
        var captured = Data()
        var iterations = 0
        while iterations < maxReadIterations {  // bounded: read-iteration cap
            iterations += 1
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            captured.append(chunk)
            guard captured.count <= stdoutCap else {
                hardStop(process)
                process.waitUntilExit()
                throw MSLError.io("bundle conf exceeds \(stdoutCap) bytes: \(path)")
            }
        }
        assert(iterations <= maxReadIterations, "read loop stayed bounded")
        return captured
    }
}
