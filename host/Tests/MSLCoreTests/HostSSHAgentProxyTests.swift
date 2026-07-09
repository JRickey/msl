import Darwin
import Foundation
import XCTest

@testable import MSLCore

final class HostSSHAgentProxyTests: XCTestCase {
    func testAllowlistForwardsReadOnlyAgentMessages() throws {
        XCTAssertNoThrow(try HostSSHAgentProxy.validateAllowed(Data([11])))
        XCTAssertNoThrow(try HostSSHAgentProxy.validateAllowed(Data([13, 0])))
        XCTAssertNoThrow(try HostSSHAgentProxy.validateAllowed(Data([27, 0])))
    }

    func testAllowlistRejectsMutationMessages() {
        XCTAssertThrowsError(try HostSSHAgentProxy.validateAllowed(Data([17]))) { error in
            XCTAssertEqual(
                error as? AuthProxyError,
                .denied("ssh-agent request 17 is not forwarded"))
        }
    }

    func testForwardWritesFrameAndReturnsAgentReply() throws {
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let clientFD = fds[0]
        let serverFD = fds[1]
        let done = expectation(description: "fake ssh-agent handled request")
        let reply = Data([12, 0, 0, 0, 0])

        Thread {
            defer {
                _ = Darwin.close(serverFD)
                done.fulfill()
            }
            do {
                let request = try Self.readFrame(fd: serverFD)
                XCTAssertEqual(request, Data([11]))
                try Self.writeFrame(reply, fd: serverFD)
            } catch {
                XCTFail("fake ssh-agent failed: \(error)")
            }
        }.start()

        let proxy = HostSSHAgentProxy(socketPath: "/tmp/fake-agent") { _ in clientFD }
        XCTAssertEqual(try proxy.forward(packet: Data([11])), reply)
        wait(for: [done], timeout: 1)
    }

    private static func readFrame(fd: Int32) throws -> Data {
        let header = try readBytes(count: 4, fd: fd)
        let count =
            (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8)
            | Int(header[3])
        return Data(try readBytes(count: count, fd: fd))
    }

    private static func writeFrame(_ packet: Data, fd: Int32) throws {
        let count = UInt32(packet.count)
        var bytes = [
            UInt8((count >> 24) & 0xff), UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff), UInt8(count & 0xff),
        ]
        bytes.append(contentsOf: packet)
        try writeBytes(bytes, fd: fd)
    }

    private static func readBytes(count: Int, fd: Int32) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), count - offset)
            }
            if got <= 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            offset += got
        }
        return bytes
    }

    private static func writeBytes(_ bytes: [UInt8], fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if sent <= 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            offset += sent
        }
    }
}
