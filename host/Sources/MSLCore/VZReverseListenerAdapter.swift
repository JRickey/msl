import Darwin
import Foundation
import Virtualization

/// The only VZ-aware piece of the reverse-vsock path. It bridges a
/// `VZVirtioSocketListenerDelegate` callback to a transport-free
/// `ReverseVsockHandler`: dup the connection fd (independent of the VZ
/// connection's lifetime), close the VZ connection, and forward. Keeping this
/// adapter separate is what lets `InteropListener`/`AuthBridgeListener` avoid
/// importing Virtualization (milestone G1).
final class VZReverseListenerAdapter: NSObject, @unchecked Sendable {
    let handler: any ReverseVsockHandler
    let port: UInt32

    init(handler: any ReverseVsockHandler, port: UInt32) {
        self.handler = handler
        self.port = port
        super.init()
    }
}

extension VZReverseListenerAdapter: VZVirtioSocketListenerDelegate {
    /// VM-queue callback: must return fast. Dup the fd, drop the VZ connection,
    /// then hand the owned fd to the handler which decides admission.
    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let raw = Darwin.dup(connection.fileDescriptor)
        connection.close()
        guard raw >= 0 else {
            handler.handleReverseAcceptFailure(errno: errno, port: port)
            return false
        }
        return handler.handleReverseConnection(fd: raw, port: port)
    }
}

extension VMHost {
    /// Install `handler` as the reverse listener for guest-initiated connects on
    /// `port` (interop 5010, auth 5040). A `VZReverseListenerAdapter` wraps the
    /// handler and is retained here as the VZ delegate so both outlive the call
    /// (VZ holds only a weak delegate). False when no VM/device. Lives beside the
    /// adapter so the VZ socket-listener types stay confined to this file.
    @discardableResult
    public func setReverseListener(_ handler: any ReverseVsockHandler, port: UInt32) -> Bool {
        precondition(port > 0, "interop port must be positive")
        let box = Box<Bool>(false)
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            defer { semaphore.signal() }
            guard let vm = self.machine,
                let device = vm.socketDevices.first as? VZVirtioSocketDevice
            else { return }
            let adapter = VZReverseListenerAdapter(handler: handler, port: port)
            let listener = VZVirtioSocketListener()
            listener.delegate = adapter
            device.setSocketListener(listener, forPort: port)
            self.interopListeners[port] = listener
            self.interopDelegates[port] = adapter
            box.value = true
        }
        semaphore.wait()
        return box.value
    }

    /// Remove the reverse listener for `port` and drop the retained objects.
    /// Safe to call on a stopped VM (the device lookup simply no-ops).
    public func removeReverseListener(port: UInt32) {
        assert(port > 0, "interop port must be positive")
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            defer { semaphore.signal() }
            let device = self.machine?.socketDevices.first as? VZVirtioSocketDevice
            device?.removeSocketListener(forPort: port)
            self.interopListeners[port] = nil
            self.interopDelegates[port] = nil
        }
        semaphore.wait()
    }
}
