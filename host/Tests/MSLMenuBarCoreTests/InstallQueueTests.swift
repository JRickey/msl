import Foundation
import MSLCore
import XCTest

@testable import MSLMenuBarCore

final class InstallQueueTests: XCTestCase {
    private func url(_ name: String) -> URL {
        return URL(fileURLWithPath: "/tmp/\(name).msl")
    }

    private func request(_ name: String) -> InstallRequest {
        return .bundle(url(name))
    }

    func testFirstSubmitStartsImmediately() {
        var queue = InstallQueue(capacity: 8)
        XCTAssertEqual(queue.submit(request("a")), .started)
        XCTAssertEqual(queue.active, request("a"))
        XCTAssertFalse(queue.isIdle)
    }

    func testSecondSubmitQueuesBehindActive() {
        var queue = InstallQueue(capacity: 8)
        XCTAssertEqual(queue.submit(request("a")), .started)
        XCTAssertEqual(queue.submit(request("b")), .queued)
        XCTAssertEqual(queue.waiting, [request("b")])
    }

    func testBacklogIsCappedAndOverflowDrops() {
        var queue = InstallQueue(capacity: 2)
        XCTAssertEqual(queue.submit(request("active")), .started)
        XCTAssertEqual(queue.submit(request("w1")), .queued)
        XCTAssertEqual(queue.submit(request("w2")), .queued)
        XCTAssertEqual(queue.submit(request("w3")), .dropped)
        XCTAssertEqual(queue.waiting.count, 2)
    }

    func testCompletePromotesInFifoOrder() {
        var queue = InstallQueue(capacity: 8)
        _ = queue.submit(request("a"))
        _ = queue.submit(request("b"))
        _ = queue.submit(request("c"))
        XCTAssertEqual(queue.complete(), request("b"))
        XCTAssertEqual(queue.complete(), request("c"))
        XCTAssertNil(queue.complete())
        XCTAssertTrue(queue.isIdle)
    }

    func testDroppedSlotReopensAfterCompletion() {
        var queue = InstallQueue(capacity: 1)
        _ = queue.submit(request("a"))
        XCTAssertEqual(queue.submit(request("b")), .queued)
        XCTAssertEqual(queue.submit(request("c")), .dropped)
        XCTAssertEqual(queue.complete(), request("b"))
        XCTAssertEqual(queue.submit(request("c")), .queued)
    }

    func testCatalogRequestDisplayNameUsesOverride() throws {
        let resolved = catalogResolved()
        let request = InstallRequest.catalog(resolved, installedName: "noble")
        XCTAssertEqual(request.displayName, "ubuntu@24.04 as noble")
    }

    private func catalogResolved() -> CatalogResolved {
        let artifact = CatalogArtifact(
            arch: "arm64", kind: .rootfsTar, compression: .xz,
            url: "https://example.invalid/rootfs.tar.xz",
            sha256: String(repeating: "b", count: 64), sizeBytes: 1024)
        let version = CatalogVersion(
            version: "24.04", aliases: [], status: .recommended, artifact: artifact, icon: nil,
            defaultUser: nil, imageSizeGiB: 8, notes: "test")
        let family = CatalogFamily(
            name: "ubuntu", friendlyName: "Ubuntu", defaultVersion: "24.04", aliases: [],
            versions: [version])
        return CatalogResolved(family: family, version: version, artifact: artifact)
    }
}
