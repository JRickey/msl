import Foundation

/// The per-boot resources `teardownState` detaches under the lock and then stops
/// outside it (stopping a forwarder or timer must never hold `stateLock`).
struct TeardownBundle {
    let wake: PowerWake?
    let forwarder: PortForwarder?
    let pollTimer: DispatchSourceTimer?
    let interop: InteropListener?
    let host: VMHost?
}
