import Darwin
import Foundation

/// CLI wrapper: parse `--socket`, `--once`, and optional `--requirement`, then
/// run one probe session. Defaults to serve-once so manual testing is clean.
func parseArguments(_ argv: [String]) -> ProbeServer? {
    precondition(!argv.isEmpty, "argv always carries the program name")
    var socketPath = ""
    var once = true
    var requirement = PeerAuth.defaultRequirement
    var index = 1
    while index < argv.count {  // bounded: index strictly increases
        let arg = argv[index]
        switch arg {
        case "--socket":
            guard index + 1 < argv.count else { return nil }
            socketPath = argv[index + 1]
            index += 2
        case "--once":
            once = true
            index += 1
        case "--serve-forever":
            once = false
            index += 1
        case "--requirement":
            guard index + 1 < argv.count else { return nil }
            requirement = argv[index + 1]
            index += 2
        default:
            return nil
        }
    }
    guard !socketPath.isEmpty, !requirement.isEmpty else { return nil }
    return ProbeServer(socketPath: socketPath, once: once, requirement: requirement)
}

let usage =
    "usage: msl-fskit-probe-server --socket <path> [--once|--serve-forever] [--requirement <dr>]\n"
guard let server = parseArguments(CommandLine.arguments) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

do {
    try server.run()
} catch {
    FileHandle.standardError.write(Data("probe-server: \(error)\n".utf8))
    exit(1)
}
