import Foundation
import MSLFSWire
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

    private func sampleSetAttr() -> FSProto.SetAttr {
        FSProto.SetAttr(
            mask: FSProto.SetAttr.modeMask | FSProto.SetAttr.sizeMask | FSProto.SetAttr.mtimeMask,
            mode: 0o100_600, size: 99,
            mtime: FSProto.Timespec(sec: 1_700_000_100, nsec: 444))
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
            .write(node: 5, offset: 4096, data: [0xde, 0xad, 0xbe, 0xef]),
            .setattr(node: 5, setattr: sampleSetAttr()),
            .create(
                parent: 1, name: "created", itemType: .file, mode: 0o100_644, uid: 1000, gid: 1000),
            .symlink(parent: 1, name: "link", target: "target", uid: 1000, gid: 1000),
            .link(node: 5, newParent: 1, newName: "hard"),
            .remove(parent: 1, name: "created", itemType: .file),
            .rename(
                node: 5, srcParent: 1, srcName: "old", dstParent: 2, dstName: "new",
                flags: 1),
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
            (12, .write(count: 4, attr: sampleAttr())),
            (13, .attr(sampleAttr())),
            (14, .attr(sampleAttr())),
            (15, .attr(sampleAttr())),
            (16, .attr(sampleAttr())),
            (17, .empty),
            (18, .attr(sampleAttr())),
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

    func testDecodeRejectsOversizeWriteBlob() {
        var bytes: [UInt8] = [12]
        bytes += Self.le64(1)
        bytes += Self.le64(5)
        bytes += Self.le64(0)
        bytes += Self.le32(UInt32(FSProto.writeRequestMax + 1))
        XCTAssertThrowsError(try FSProto.RequestFrame.decode(bytes)) { error in
            XCTAssertEqual(
                error as? FSProto.WireError, .oversizeBlob(FSProto.writeRequestMax + 1))
        }
    }

    /// Byte-for-byte identical to the guest `msl-wire::fs` golden vector: a
    /// getattr reply (id 7, op 3, errno 0) carrying `sampleAttr()`. If either
    /// side's encoding drifts, this and its Rust twin fail together.
    func testGetattrReplyGoldenVector() throws {
        let frame = FSProto.ReplyFrame.ok(id: 7, op: 3, body: .attr(sampleAttr()))
        let hex = try frame.encode().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, Self.getattrGoldenHex)
    }

    /// Shared with the guest `msl-wire::fs` tests: write request id 42,
    /// node 5, offset 4096, data `deadbeef`.
    func testWriteRequestGoldenVector() throws {
        let frame = FSProto.RequestFrame(
            id: 42, request: .write(node: 5, offset: 4096, data: [0xde, 0xad, 0xbe, 0xef]))
        let hex = try frame.encode().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, Self.writeRequestGoldenHex)
    }

    /// Shared with the guest `msl-wire::fs` tests: write reply id 42,
    /// op 12, count 4, carrying `sampleAttr()`.
    func testWriteReplyGoldenVector() throws {
        let frame = FSProto.ReplyFrame.ok(
            id: 42, op: 12, body: .write(count: 4, attr: sampleAttr()))
        let hex = try frame.encode().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, Self.writeReplyGoldenHex)
    }

    private static let getattrGoldenHex =
        "07000000000000000300000000" + attrGoldenHex

    private static let writeRequestGoldenHex =
        "0c2a000000000000000500000000000000001000000000000004000000deadbeef"

    private static let writeReplyGoldenHex =
        "2a000000000000000c0000000004000000" + attrGoldenHex

    private static let attrGoldenHex =
        "05000000000000009210000000000000010000000000000001a4810000e8030000e8030000"
        + "010000003930000000000000004000000000000000f15365000000006f000000"
        + "01f1536500000000de00000002f15365000000004d01000000000000"

    private static func le32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private static func le64(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}
