import Foundation
import MSLCore
import MSLMenuBarCore

struct HostSettingsLoad: Sendable {
    let settings: MSLHostSettings
    let facts: SharedVMHardwareFacts
}

enum AppRuntimeAction {
    private static let queue = DispatchQueue(label: "dev.msl.app.runtime")

    static func openShell(home: MSLHome, name: String) async -> String? {
        await run { try LauncherRuntime.openShell(home: home, name: name) }
    }

    static func stop(home: MSLHome, name: String) async -> LifecycleOutcome {
        if let error = await run({ try DaemonClient.down(home, name: name, all: false) }) {
            return .failed(message: error)
        }
        return .succeeded
    }

    static func restartMac() async -> String? {
        await run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \"System Events\" to restart"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MSLError.io("macOS restart request failed")
            }
        }
    }

    private static func run(_ body: @escaping @Sendable () throws -> Void) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try body()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: "\(error)")
                }
            }
        }
    }
}

enum AppSettingsActions {
    private static let queue = DispatchQueue(label: "dev.msl.app.settings")

    static func loadHost(home: MSLHome) async throws -> HostSettingsLoad {
        try await run {
            HostSettingsLoad(
                settings: try MSLHostSettingsStore(home: home).load(),
                facts: SharedVMHardwareFacts.discover())
        }
    }

    static func saveHost(
        home: MSLHome, draft: HostSettingsDraft, changes: HostSettingsChanges
    ) async throws -> MSLHostSettings {
        try await run {
            return try MSLHostSettingsStore(home: home).update { settings in
                try changes.apply(draft: draft, to: &settings)
            }
        }
    }

    static func saveDistro(
        home: MSLHome, draft: DistroSettingsDraft, changes: DistroSettingsChanges
    ) async throws -> Registry {
        try await run {
            try RegistryStore(home: home).update { registry in
                try changes.apply(draft: draft, to: &registry)
            }
        }
    }

    static func restartDistro(home: MSLHome, name: String) async -> LifecycleOutcome {
        await runLifecycle {
            do {
                try DaemonClient.down(home, name: name, all: false)
            } catch {
                return .failed(message: "\(error)")
            }
            do {
                try DaemonClient.up(home, name: name)
                return .succeeded
            } catch {
                return .failed(message: "\(error)")
            }
        }
    }

    static func restartSubsystem(home: MSLHome) async -> LifecycleOutcome {
        await runLifecycle {
            do {
                try DaemonClient.shutdown(home)
            } catch {
                return .failed(message: "\(error)")
            }
            do {
                try waitForDaemonExit(home: home)
                try DaemonClient.ensureRunning(home)
                _ = try DaemonClient.status(home)
                return .succeeded
            } catch {
                return .failed(message: "\(error)")
            }
        }
    }

    static func startSubsystem(home: MSLHome) async -> LifecycleOutcome {
        await runLifecycle {
            do {
                try DaemonClient.ensureRunning(home)
                _ = try DaemonClient.status(home)
                return .succeeded
            } catch {
                return .failed(message: "\(error)")
            }
        }
    }

    static func shutdownSubsystem(home: MSLHome) async -> LifecycleOutcome {
        await runLifecycle {
            do {
                try DaemonClient.shutdown(home)
            } catch {
                return .failed(message: "\(error)")
            }
            do {
                try waitForDaemonExit(home: home)
                return .succeeded
            } catch {
                return .failed(message: "\(error)")
            }
        }
    }

    private static func waitForDaemonExit(home: MSLHome) throws {
        for _ in 0..<40 {  // bounded: 40 * 25ms = 1s
            if !DaemonClient.isRunning(home) { return }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw MSLError.timedOut("daemon did not stop within 1 second")
    }

    private static func run<Value: Sendable>(
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runLifecycle(
        _ body: @escaping @Sendable () -> LifecycleOutcome
    ) async -> LifecycleOutcome {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
