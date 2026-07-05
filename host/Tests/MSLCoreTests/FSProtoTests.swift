import Foundation
import XCTest

@testable import MSLCore

final class FSProtoTests: XCTestCase {
    private func sampleAttr() -> FSProto.Attr {
        FSProto.Attr(
            nodeID: 5, fileID: 4242, parentID: 1, itemType: .file, mode: 0o100_644, uid: 1000,
            gid: 1000, nlink: 1, size: 12345, allocSize: 16384,
            atime: FSProto.Timespec(sec: 1_700_000_000, nsec: 111),
            mtime: FSProto.Timespec(sec: 1_700_000_001, nsec: 222),
            ctime: FSProto.Timespec(sec: 1_700_000_002, nsec: 333), flags: 0)
    }

    func testRequestRoundTripAllOps() throws {
        let requests: [FSProto.Request] = [
            .statfs,
            .lookup(parent: 1, name: "etc"),
            .getattr(node: 5, wanted: 0),
            .readdirplus(node: 1, cookie: 0, maxEntries: 128, wanted: 0),
            .open(node: 5, mode: 0),
            .read(handle: 9, offset: 4096, length: 65536),
            .closeFile(handle: 9),
            .readlink(node: 7),
            .reclaim(node: 5),
            .sync,
            .close,
        ]
        for (index, request) in requests.enumerated() {
            let frame = FSProto.RequestFrame(id: UInt64(index) + 1, request: request)
            let decoded = try FSProto.RequestFrame.decode(try frame.encode())
            XCTAssertEqual(decoded, frame)
        }
    }

    func testReplyRoundTripBodies() throws {
        let bodies: [(UInt8, FSProto.ReplyBody)] = [
            (
                1,
                .statfs(
                    FSProto.Statfs(
                        blocks: 1000, bfree: 500, bavail: 400, files: 200, ffree: 100, bsize: 4096,
                        namemax: 255))
            ),
            (3, .attr(sampleAttr())),
            (
                4,
                .readdirplus(
                    eof: true, nextCookie: 0,
                    entries: [FSProto.DirEntry(name: "os-release", attr: sampleAttr())])
            ),
            (5, .open(handle: 42)),
            (6, .read(data: [1, 2, 3, 4], eof: false)),
            (8, .readlink(target: "/usr/lib")),
            (7, .empty),
        ]
        for (op, body) in bodies {
            let frame = FSProto.ReplyFrame.ok(id: 7, op: op, body: body)
            let decoded = try FSProto.ReplyFrame.decode(try frame.encode())
            XCTAssertEqual(decoded, frame)
        }
    }

    func testErrnoRoundTripAndRetryableStale() throws {
        let notFound = FSProto.ReplyFrame.error(
            id: 3, op: 2, errno: ENOENT, message: "no such file")
        XCTAssertEqual(try FSProto.ReplyFrame.decode(try notFound.encode()), notFound)
        // ESTALE is the retryable open-handle-loss signal the appex reopens on.
        let stale = FSProto.ReplyFrame.error(id: 4, op: 6, errno: ESTALE, message: "handle evicted")
        let decoded = try FSProto.ReplyFrame.decode(try stale.encode())
        guard case .failure(let error) = decoded.result else {
            return XCTFail("expected an error result")
        }
        XCTAssertEqual(error.errno, ESTALE)
    }

    func testDecodeRejectsTrailingBytes() throws {
        var bytes = try FSProto.RequestFrame(id: 1, request: .statfs).encode()
        bytes.append(0xff)
        XCTAssertThrowsError(try FSProto.RequestFrame.decode(bytes)) { error in
            XCTAssertEqual(error as? FSProto.WireError, .trailingBytes)
        }
    }

    func testDecodeRejectsTruncated() throws {
        let bytes = try FSProto.RequestFrame(id: 1, request: .lookup(parent: 1, name: "etc"))
            .encode()
        XCTAssertThrowsError(try FSProto.RequestFrame.decode(Array(bytes.dropLast(2)))) { error in
            XCTAssertEqual(error as? FSProto.WireError, .truncated)
        }
    }

    func testDecodeRejectsBadOp() {
        let bytes: [UInt8] = [99, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertThrowsError(try FSProto.RequestFrame.decode(bytes)) { error in
            XCTAssertEqual(error as? FSProto.WireError, .badOp(99))
        }
    }

    /// Byte-for-byte identical to the guest `msl-wire::fs` golden vector: a
    /// getattr reply (id 7, op 3, errno 0) carrying `sampleAttr()`. If either
    /// side's encoding drifts, this and its Rust twin fail together.
    func testGetattrReplyGoldenVector() throws {
        let frame = FSProto.ReplyFrame.ok(id: 7, op: 3, body: .attr(sampleAttr()))
        let hex = try frame.encode().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, Self.goldenHex)
    }

    private static let goldenHex =
        "0700000000000000030000000005000000000000009210000000000000"
        + "010000000000000001a4810000e8030000e8030000010000003930000000"
        + "000000004000000000000000f15365000000006f00000001f15365000000"
        + "00de00000002f15365000000004d01000000000000"
}
