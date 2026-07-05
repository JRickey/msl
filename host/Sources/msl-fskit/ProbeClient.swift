import Darwin
import Foundation

/// Result of the app-group Unix-domain probe. `connected` means the socket
/// accepted the write; `reply` is the server's response line; `detail` carries
/// the failure reason for logging when `connected` is false.
struct ProbeOutcome: Sendable {
    let connected: Bool
    let reply: String
    let detail: String
}

/// Connects the sandboxed FSKit appex to the daemon's app-group Unix-domain
/// socket, sends one newline-terminated probe message, and reads a bounded
/// reply. Every syscall is time-bounded so a `mount` attempt cannot hang.
enum ProbeClient {
    private static let timeoutSeconds = 2.0
    private static let socketName = "msl-fskit-probe.sock"

    static func run(appGroup: String, resource: MSLResourceURL, appexID: String) -> ProbeOutcome {
        precondition(!appGroup.isEmpty, "app group must not be empty")
        precondition(!appexID.isEmpty, "appex id must not be empty")
        guard let path = socketPath(appGroup: appGroup) else {
            return ProbeOutcome(
                connected: false, reply: "", detail: "no group container for \(appGroup)")
        }
        let message = probeLine(resource: resource, appexID: appexID)
        return connectAndProbe(path: path, message: message)
    }

    /// `<groupContainer>/msl-fskit-probe.sock`, or nil when the sandbox denies
    /// the group container (the primary open question this spike answers).
    static func socketPath(appGroup: String) -> String? {
        precondition(!appGroup.isEmpty, "app group must not be empty")
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        guard let container = base else { return nil }
        let sock = container.appendingPathComponent(socketName)
        assert(sock.isFileURL, "container URL must be a file URL")
        return sock.path
    }

    private static func probeLine(resource: MSLResourceURL, appexID: String) -> Data {
        precondition(!appexID.isEmpty, "appex id must not be empty")
        let fields: [String: String] = [
            "distro": resource.distro, "mount": resource.mount, "nonce": resource.nonce,
            "appex": appexID, "pid": String(getpid()),
        ]
        let json = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data("{}".utf8)
        assert(!json.isEmpty, "serialized probe line must be non-empty")
        return json + Data("\n".utf8)
    }

    private static func connectAndProbe(path: String, message: Data) -> ProbeOutcome {
        precondition(!path.isEmpty, "socket path must not be empty")
        precondition(!message.isEmpty, "probe message must not be empty")
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return ProbeOutcome(connected: false, reply: "", detail: "socket() errno=\(errno)")
        }
        defer { _ = Darwin.close(fd) }
        applyTimeout(fd, SO_SNDTIMEO)
        applyTimeout(fd, SO_RCVTIMEO)
        guard connect(fd, path: path) else {
            return ProbeOutcome(
                connected: false, reply: "", detail: "connect(\(path)) errno=\(errno)")
        }
        guard writeAll(fd, message) else {
            return ProbeOutcome(connected: false, reply: "", detail: "write errno=\(errno)")
        }
        let reply = readLine(fd)
        return ProbeOutcome(connected: true, reply: reply, detail: "")
    }

    private static func applyTimeout(_ fd: Int32, _ option: Int32) {
        assert(fd >= 0, "fd must be valid")
        var tv = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func connect(_ fd: Int32, path: String) -> Bool {
        precondition(fd >= 0, "fd must be valid")
        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { return false }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for idx in 0..<bytes.count { dst[idx] = CChar(bitPattern: bytes[idx]) }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        return rc == 0
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        precondition(fd >= 0, "fd must be valid")
        precondition(!data.isEmpty, "data must not be empty")
        let bytes = [UInt8](data)
        var sent = 0
        for _ in 0..<(bytes.count + 8) {  // bounded: each write advances >=1 byte
            if sent == bytes.count { return true }
            let count = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            if count > 0 {
                sent += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return false
    }

    private static func readLine(_ fd: Int32) -> String {
        assert(fd >= 0, "fd must be valid")
        var out = [UInt8]()
        var byte: UInt8 = 0
        for _ in 0..<256 {  // bounded: a probe reply is a short single line
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                if byte == 0x0A { break }
                out.append(byte)
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}
