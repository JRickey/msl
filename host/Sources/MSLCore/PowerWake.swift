import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Watches IOKit system-power notifications on a dedicated run-loop thread and
/// invokes `onWake` when the machine wakes, so the caller can resync guest time.
/// The IOKit registration requires a C-ABI callback (see `powerCallback`), the
/// one function-pointer use permitted for a system ABI.
///
/// Invariant: while registered, a PowerWake must never be deallocated — the
/// callback holds an unretained pointer to it. `UpDriver` retains it, and
/// `UpDriver` is itself pinned for process lifetime; deregister via `stop()`
/// before dropping the last reference.
public final class PowerWake: @unchecked Sendable {
    // IOMessage constants (Swift cannot import the iokit_common_msg macros):
    // value = sys_iokit (0xE0000000) | message code.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let onWake: @Sendable () -> Void
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notifyPort: IONotificationPortRef?
    private var runLoop: CFRunLoop?
    private let thread: Thread

    public init(onWake: @escaping @Sendable () -> Void) {
        self.onWake = onWake
        let box = ThreadBox()
        self.thread = Thread { box.body?() }
        box.body = { [weak self] in self?.runLoopMain() }
        thread.name = "msl.powerwake"
    }

    /// Start the notification thread. Registration failures are non-fatal —
    /// logged on the thread; time sync simply won't fire on wake.
    public func start() {
        thread.start()
    }

    /// Deregister from system power and stop the run loop. Safe to call once;
    /// currently unused (PowerWake is a process-lifetime object).
    public func stop() {
        guard let port = notifyPort else { return }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        IONotificationPortDestroy(port)
        notifyPort = nil
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    /// Deliver the wake callback; called only from the C trampoline.
    func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        if messageType == Self.canSystemSleep || messageType == Self.systemWillSleep {
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        } else if messageType == Self.systemHasPoweredOn {
            onWake()
        }
    }

    private func runLoopMain() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var port: IONotificationPortRef?
        var localNotifier: io_object_t = 0
        let connect = IORegisterForSystemPower(context, &port, powerCallback, &localNotifier)
        guard connect != 0, let port else {
            write(line: "msl: power notifications unavailable (time sync on wake disabled)")
            return
        }
        rootPort = connect
        notifier = localNotifier
        notifyPort = port
        runLoop = CFRunLoopGetCurrent()
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        CFRunLoopRun()
    }

    private func write(line: String) {
        try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
    }
}

/// Holds the thread body so it can be assigned after `Thread` construction
/// without capturing a not-yet-initialized `self`.
private final class ThreadBox: @unchecked Sendable {
    var body: (() -> Void)?
}

/// C-ABI trampoline required by IORegisterForSystemPower; recovers the
/// `PowerWake` from the unretained refcon and forwards the message.
private func powerCallback(
    _ refcon: UnsafeMutableRawPointer?, _ service: io_service_t, _ messageType: UInt32,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let wake = Unmanaged<PowerWake>.fromOpaque(refcon).takeUnretainedValue()
    wake.handle(messageType: messageType, argument: messageArgument)
}
