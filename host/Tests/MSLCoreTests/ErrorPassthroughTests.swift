import Darwin
import Foundation
import XCTest

@testable import MSLCore

/// Verifies a guest `ok:false` reply reaches the caller with its original text
/// (via `MSLError.remote`), not remapped to a generic protocol error.
final class ControlErrorPassthroughTests: XCTestCase {
    private func socketPair() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        let rc = fds.withUnsafeMutableBufferPointer {
            socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress)
        }
        guard rc == 0 else { throw MSLError.io("socketpair failed: errno=\(errno)") }
        return (fds[0], fds[1])
    }

    func testGuestErrorSurfacesVerbatim() throws {
        let (clientFD, guestFD) = try socketPair()
        // Pre-load the guest's framed error reply (id 1 matches ping's first id).
        let guest = try VsockClient(fileDescriptor: guestFD)
        defer { guest.close() }
        try guest.send(Data(#"{"id":1,"ok":false,"error":"distro not running"}"#.utf8))

        let control = try ControlClient(client: try VsockClient(fileDescriptor: clientFD))
        defer { control.close() }
        XCTAssertThrowsError(try control.ping()) { error in
            guard case MSLError.remote(let message) = error else {
                return XCTFail("expected MSLError.remote, got \(error)")
            }
            XCTAssertEqual(message, "distro not running")
        }
    }
}
