import Darwin
import Foundation
import MSLCore
import MSLGui

/// Out-of-process GUI presenter. The daemon spawns it (`GuiPresenterLauncher`)
/// when a `gui_launch` finds no presenter for `(distro, user)`. It receives the
/// runtime identity on argv and its single-use attach token over an inherited
/// pipe fd, consumes the token through the daemon's `gui_attach` op to claim the
/// raw surface-plane fd, then runs the AppKit loop. Keeping this a separate
/// executable is what lets the daemon and CLI stay AppKit-free.
@main
struct MSLPresenter {
    static func main() {
        do {
            try run()
        } catch {
            let message = (error as? MSLError)?.description ?? "\(error)"
            FileHandle.standardError.write(Data("msl-presenter: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            throw MSLError.configuration("usage: msl-presenter <home> <distro> <user> [csv]")
        }
        let home = MSLHome(root: URL(fileURLWithPath: args[1]))
        let distro = args[2]
        let user = args[3].isEmpty ? nil : args[3]
        guard !distro.isEmpty else {
            throw MSLError.configuration("presenter distro must not be empty")
        }
        let requestedCsv = args.count >= 5 ? args[4] : ""
        let csv = requestedCsv.isEmpty ? defaultCsvPath(home: home, distro: distro) : requestedCsv
        assert(!csv.isEmpty, "presenter csv path is non-empty")
        let token = try readToken(from: tokenDescriptor())
        let fd = try attach(home: home, distro: distro, user: user, token: token)
        let channel = try GuiChannel(fd: fd)
        MainActor.assumeIsolated {
            GuiPresenter(channel: channel, distro: distro, csvPath: csv).run()
        }
    }

    /// Consume the token on a fresh daemon connection and return the raw
    /// surface-plane fd relayed back over it.
    private static func attach(
        home: MSLHome, distro: String, user: String?, token: String
    ) throws -> Int32 {
        precondition(!distro.isEmpty, "attach needs a distro")
        precondition(!token.isEmpty, "attach needs a token")
        let control = try LocalClient.connect(path: DaemonClient.socketPath(home))
        defer { control.close() }
        let fd = try control.guiAttachRaw(distro: distro, user: user, token: token)
        assert(fd >= 0, "guiAttachRaw returns a valid fd or throws")
        return fd
    }

    /// The inherited fd carrying the attach token (`MSL_GUI_TOKEN_FD`, defaulting
    /// to the launcher's fixed descriptor).
    private static func tokenDescriptor() -> Int32 {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["MSL_GUI_TOKEN_FD"], let fd = Int32(raw), fd >= 0 { return fd }
        return GuiPresenterLauncher.tokenFD
    }

    /// Read the token from the inherited pipe until EOF, bounded in both bytes and
    /// time so a missing or wedged parent can never hang the presenter.
    private static func readToken(from fd: Int32) throws -> String {
        precondition(fd >= 0, "token fd must be valid")
        let maxLen = 256
        var buffer = [UInt8]()
        let cap = maxLen + 8  // bounded: each iteration consumes >=1 byte or ends
        for _ in 0..<cap {
            if buffer.count >= maxLen { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 5000)
            if ready == 0 { throw MSLError.io("timed out waiting for the presenter token") }
            if ready < 0 {
                if errno == EINTR { continue }
                throw MSLError.io("poll for presenter token failed errno=\(errno)")
            }
            var chunk = [UInt8](repeating: 0, count: maxLen)
            let read = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, maxLen)
            }
            if read == 0 { break }
            if read < 0 {
                if errno == EINTR { continue }
                throw MSLError.io("presenter token read failed errno=\(errno)")
            }
            buffer.append(contentsOf: chunk[0..<read])
        }
        return try validated(buffer)
    }

    private static func validated(_ buffer: [UInt8]) throws -> String {
        guard let decoded = String(bytes: buffer, encoding: .utf8) else {
            throw MSLError.protocolMismatch("presenter token is not valid UTF-8")
        }
        let token = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == LocalProto.tokenHexLength else {
            throw MSLError.protocolMismatch("presenter token has unexpected length \(token.count)")
        }
        assert(!token.isEmpty, "validated token is non-empty")
        return token
    }

    private static func defaultCsvPath(home: MSLHome, distro: String) -> String {
        assert(!distro.isEmpty, "csv path needs a distro")
        return home.logsDirectory.appendingPathComponent("gui-\(distro).csv").path
    }
}
