import Darwin
import Foundation

/// Decides whether a daemon launched from an `.app` bundle should self-exit once
/// that bundle disappears (dragged to Trash). Pure and side-effect free so the
/// debounce can be unit-tested without timers or signals. A `nil` bundle path
/// means the daemon was run from a dev build tree and the watchdog stays disarmed.
struct BundleWatchdog: Sendable {
    let bundlePath: String?
    let missThreshold: Int

    struct Decision: Equatable {
        let act: Bool
        let missCount: Int
    }

    init(bundlePath: String?, missThreshold: Int = 3) {
        precondition(missThreshold > 0, "miss threshold must be positive")
        precondition(bundlePath.map { !$0.isEmpty } ?? true, "armed path must be non-empty")
        self.bundlePath = bundlePath
        self.missThreshold = missThreshold
    }

    /// Fold one observation into the miss counter. A present bundle (or a
    /// disarmed watchdog) resets to zero; `act` fires once misses reach the
    /// threshold. `fileExists` is injected so tests need no real filesystem.
    func decide(missCount: Int, fileExists: (String) -> Bool) -> Decision {
        precondition(missCount >= 0, "miss count must not be negative")
        precondition(missThreshold > 0, "miss threshold must be positive")
        guard let path = bundlePath, !path.isEmpty else {
            return Decision(act: false, missCount: 0)
        }
        if fileExists(path) {
            return Decision(act: false, missCount: 0)
        }
        let next = missCount + 1
        assert(next > 0, "miss count must advance")
        return Decision(act: next >= missThreshold, missCount: next)
    }

    /// The `.app` bundle of the running executable, or `nil` when the layout is
    /// not `<bundle>.app/Contents/MacOS/<exe>` (a dev build — stays disarmed).
    /// Walks the executable path (not `Bundle.main.bundlePath`, which is
    /// unreliable once the bundle is moved).
    static func resolveBundlePath(
        executablePath: String? = Bundle.main.executablePath
    ) -> String? {
        guard let executablePath, !executablePath.isEmpty else { return nil }
        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard components.count >= 3 else { return nil }
        let upper = components.count - 3
        var index = 0
        while index <= upper {  // bounded: path component count
            assert(index + 2 < components.count, "lookahead within bounds")
            let isBundleExecutable =
                components[index].hasSuffix(".app")
                && components[index + 1] == "Contents"
                && components[index + 2] == "MacOS"
            if isBundleExecutable {
                return NSString.path(withComponents: Array(components[0...index]))
            }
            index += 1
        }
        return nil
    }
}

extension DaemonCore {
    /// Exit the daemon once its own `.app` bundle has been gone for the watchdog's
    /// threshold of consecutive ticks; disarmed for dev builds. Routes through the
    /// installed SIGTERM path so teardown runs exactly once.
    func checkBundleWatchdog() {
        let decision = bundleWatchdog.decide(missCount: bundleMissCount) {
            FileManager.default.fileExists(atPath: $0)
        }
        assert(decision.missCount >= 0, "miss count must not be negative")
        bundleMissCount = decision.missCount
        guard decision.act else { return }
        if let path = bundleWatchdog.bundlePath {
            log("app bundle removed (\(path)); shutting down")
        }
        let raised = Darwin.raise(SIGTERM)
        assert(raised == 0, "raise(SIGTERM) must succeed")
        if raised != 0 { exit(0) }
    }
}
