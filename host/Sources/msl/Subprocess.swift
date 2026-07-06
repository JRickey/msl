import Foundation

/// Minimal blocking subprocess runner for the CLI's `/sbin/mount` and
/// `/sbin/umount` invocations: capture the exit status and stderr so mount
/// errors surface in the initiating terminal.
enum Subprocess {
    struct Result {
        let status: Int32
        let stderr: String
    }

    static func run(_ executable: String, _ arguments: [String]) -> Result {
        precondition(!executable.isEmpty, "executable path must not be empty")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, stderr: "spawn \(executable) failed: \(error)")
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: errData, encoding: .utf8) ?? ""
        return Result(
            status: process.terminationStatus,
            stderr: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func runInteractive(_ executable: String, _ arguments: [String]) -> Result {
        precondition(!executable.isEmpty, "executable path must not be empty")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            return Result(status: -1, stderr: "spawn \(executable) failed: \(error)")
        }
        process.waitUntilExit()
        return Result(status: process.terminationStatus, stderr: "")
    }
}
