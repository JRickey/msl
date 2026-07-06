import Foundation
import MSLCore
import MSLMenuBarCore

/// Result of an in-process install attempt, carried Sendably back to the main
/// actor for notification and queue advancement.
enum InstallOutcome: Sendable {
    case installed(name: String)
    case failed(message: String)
}

/// Off-main daemon probe. The synchronous `LocalClient` round-trip runs on a
/// private serial queue and resolves a continuation, so the main thread never
/// blocks on the socket.
enum StatusProbe {
    private static let queue = DispatchQueue(label: "dev.msl.menubar.probe")

    static func probeAsync(home: MSLHome) async -> DaemonProbe {
        await withCheckedContinuation { (cont: CheckedContinuation<DaemonProbe, Never>) in
            queue.async { cont.resume(returning: compute(home: home)) }
        }
    }

    private static func compute(home: MSLHome) -> DaemonProbe {
        guard DaemonClient.isRunning(home) else {
            return DaemonProbe(running: false, status: nil, defaultDistro: nil)
        }
        let status = try? DaemonClient.status(home)
        let registryDefault = (try? Registry.load(from: home.registryURL))?.defaultDistro
        return DaemonProbe(running: status != nil, status: status, defaultDistro: registryDefault)
    }
}

/// Off-main daemon lifecycle actions. Both reuse the CLI's client helpers and
/// return nil on success or a message describing the failure.
enum DaemonAction {
    private static let queue = DispatchQueue(label: "dev.msl.menubar.daemon")

    static func start(home: MSLHome) async -> String? {
        return await run(home: home) { try DaemonClient.ensureRunning($0) }
    }

    static func shutdown(home: MSLHome) async -> String? {
        return await run(home: home) { try DaemonClient.shutdown($0) }
    }

    private static func run(
        home: MSLHome, _ body: @escaping @Sendable (MSLHome) throws -> Void
    ) async -> String? {
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            queue.async {
                do {
                    try body(home)
                    cont.resume(returning: nil)
                } catch {
                    cont.resume(returning: "\(error)")
                }
            }
        }
    }
}

enum FSKitActionResult: Equatable {
    case ready
    case restartRequired
    case failed(String)
}

enum FSKitAction {
    private typealias EnableContinuation = CheckedContinuation<FSKitActionResult, Never>

    private static let queue = DispatchQueue(label: "dev.msl.menubar.fskit")

    static func status() async -> Bool {
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async { cont.resume(returning: (try? FSKitEnablement.isEnabled()) ?? false) }
        }
    }

    static func enable() async -> FSKitActionResult {
        return await withCheckedContinuation { (cont: EnableContinuation) in
            queue.async {
                do {
                    _ = try FSKitEnablement.enable()
                    cont.resume(returning: restartIfRunning() ? .ready : .restartRequired)
                } catch {
                    cont.resume(returning: .failed("\(error)"))
                }
            }
        }
    }

    private static func restartIfRunning() -> Bool {
        let probe = run("/usr/bin/pgrep", ["-x", "fskitd"])
        guard probe == 0 else { return true }
        return run("/usr/bin/killall", ["fskitd"]) == 0
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        assert(!executable.isEmpty, "executable path must not be empty")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Runs one `.msl` install in-process on a private serial queue, mirroring the
/// CLI's `install` command via `MenuBarInstall` + `InstallDriver`.
enum InstallRunner {
    private static let queue = DispatchQueue(label: "dev.msl.menubar.install.work")

    static func run(home: MSLHome, bundlePath: String) async -> InstallOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<InstallOutcome, Never>) in
            queue.async { cont.resume(returning: perform(home: home, bundlePath: bundlePath)) }
        }
    }

    private static func perform(home: MSLHome, bundlePath: String) -> InstallOutcome {
        assert(!bundlePath.isEmpty, "install bundle path must not be empty")
        do {
            let prepared = try MenuBarInstall.prepare(bundlePath: bundlePath, home: home)
            let entry = try InstallDriver(home: home).install(
                plan: prepared.plan, options: prepared.options)
            return .installed(name: entry.name)
        } catch {
            return .failed(message: "\(error)")
        }
    }
}
