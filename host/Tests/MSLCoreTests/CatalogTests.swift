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
        XCTAssertEqual(resolved.version.icon?.kind, .svg)
        XCTAssertEqual(resolved.version.icon?.url, "https://cdn.simpleicons.org/ubuntu")
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

    func testSelectorSyntaxRejectsUnsafeCharacters() {
        XCTAssertTrue(Catalog.isValidSelectorSyntax("ubuntu@24.04"))
        XCTAssertFalse(Catalog.isValidSelectorSyntax("../ubuntu"))
        XCTAssertFalse(Catalog.isValidSelectorSyntax("ubuntu noble"))
    }

    func testListRowsHideExperimentalByDefault() throws {
        let catalog = try Catalog.loadEmbedded()
        let rows = catalog.listRows(includeExperimental: false)
        XCTAssertEqual(rows.map(\.name), ["ubuntu"])
        XCTAssertEqual(rows.first?.status, .recommended)
    }

    func testKnownDistroIconsResolveByAliases() throws {
        XCTAssertEqual(DistroIconCatalog.icon(for: "ubuntu")?.kind, .svg)
        XCTAssertEqual(DistroIconCatalog.displayName(for: "ubuntu"), "Ubuntu")
        XCTAssertEqual(
            DistroIconCatalog.icon(for: "arch")?.url, "https://cdn.simpleicons.org/archlinux")
        XCTAssertEqual(DistroIconCatalog.displayName(for: "arch"), "Arch Linux")
        XCTAssertEqual(
            DistroIconCatalog.icon(for: "archlinux")?.url, "https://cdn.simpleicons.org/archlinux")
        XCTAssertEqual(DistroIconCatalog.icon(for: "fedora")?.kind, .svg)
        XCTAssertEqual(DistroIconCatalog.displayName(for: "fedora"), "Fedora")
        XCTAssertNil(DistroIconCatalog.icon(for: "custom"))
    }

    func testCatalogIconRequiresHTTPS() throws {
        let catalog = catalogWithIcon(
            CatalogIcon(
                kind: .png, url: "http://example.invalid/icon.png",
                sha256: String(repeating: "a", count: 64), sizeBytes: 16))
        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertTrue(String(describing: error).contains("HTTPS"))
        }
    }

    func testCatalogIconRequiresSHA256() throws {
        let catalog = catalogWithIcon(
            CatalogIcon(
                kind: .icns, url: "https://example.invalid/icon.icns", sha256: "abc", sizeBytes: 16)
        )
        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertTrue(String(describing: error).contains("SHA256"))
        }
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

    private func catalogWithIcon(_ icon: CatalogIcon) -> Catalog {
        let artifact = CatalogArtifact(
            arch: "arm64", kind: .rootfsTar, compression: .xz,
            url: "https://example.invalid/rootfs.tar.xz",
            sha256: String(repeating: "b", count: 64), sizeBytes: 1024)
        let version = CatalogVersion(
            version: "1", aliases: [], status: .recommended, artifact: artifact, icon: icon,
            defaultUser: nil, imageSizeGiB: 8, notes: "test")
        let family = CatalogFamily(
            name: "test", friendlyName: "Test", defaultVersion: "1", aliases: [],
            versions: [version])
        return Catalog(schema: 1, generatedAt: "test", families: [family])
    }
}
