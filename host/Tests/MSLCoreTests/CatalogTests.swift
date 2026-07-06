import Foundation
import XCTest

@testable import MSLCore

final class CatalogTests: XCTestCase {
    func testEmbeddedCatalogResolvesDefaultUbuntu() throws {
        let resolved = try Catalog.loadEmbedded().resolve(selector: "ubuntu")
        XCTAssertEqual(resolved.family.name, "ubuntu")
        XCTAssertEqual(resolved.version.version, "24.04")
        XCTAssertEqual(resolved.artifact.compression, .xz)
        XCTAssertTrue(resolved.artifact.url.hasPrefix("https://"))
    }

    func testEmbeddedCatalogResolvesCaseAndVersionAlias() throws {
        let catalog = try Catalog.loadEmbedded()
        XCTAssertEqual(try catalog.resolve(selector: "Ubuntu@Noble").selector, "ubuntu@24.04")
        XCTAssertEqual(try catalog.resolve(selector: "ubuntu@lts").selector, "ubuntu@24.04")
    }

    func testUnknownSelectorThrowsHelpfulError() throws {
        let catalog = try Catalog.loadEmbedded()
        XCTAssertThrowsError(try catalog.resolve(selector: "arch")) { error in
            XCTAssertTrue(String(describing: error).contains("msl catalog list"))
        }
    }

    func testListRowsHideExperimentalByDefault() throws {
        let catalog = try Catalog.loadEmbedded()
        let rows = catalog.listRows(includeExperimental: false)
        XCTAssertEqual(rows.map(\.name), ["ubuntu"])
        XCTAssertEqual(rows.first?.status, .recommended)
    }

    func testDirectInstallPlanDoesNotDependOnSuffix() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-catalog-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let plan = try InstallPlan.make(
            name: "ubuntu", source: .tarball(url, .xz), sizeGiB: 8, existingNames: [])
        XCTAssertEqual(plan.name, "ubuntu")
        guard case .tarball(_, let compression) = plan.source else {
            return XCTFail("expected tarball")
        }
        XCTAssertEqual(compression, .xz)
    }
}
