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
        XCTAssertEqual(resolved.version.icon?.url, "https://cdn.simpleicons.org/ubuntu/FFFFFF")
        XCTAssertEqual(resolved.version.icon?.backgroundHex, "E95420")
    }

    func testEmbeddedCatalogResolvesExperimentalDistros() throws {
        let catalog = try Catalog.loadEmbedded()
        let cases = [
            ("almalinux@10", "almalinux@10.2", TarCompression.gzip),
            ("debian@trixie", "debian@13", TarCompression.gzip),
            ("fedoralinux@44", "fedora@44", TarCompression.gzip),
            ("kali-linux@rolling", "kali@2026.2", TarCompression.gzip),
            ("opensuse-tumbleweed@20260422", "opensuse@tumbleweed", TarCompression.xz),
        ]

        for item in cases {
            let resolved = try catalog.resolve(selector: item.0)
            XCTAssertEqual(resolved.selector, item.1)
            XCTAssertEqual(resolved.version.status, .experimental)
            XCTAssertEqual(resolved.artifact.compression, item.2)
            XCTAssertEqual(resolved.version.icon?.kind, .svg)
            XCTAssertNotNil(resolved.version.icon?.backgroundHex)
        }
    }

    func testEmbeddedCatalogResolvesCaseAndVersionAlias() throws {
        let catalog = try Catalog.loadEmbedded()
        XCTAssertEqual(try catalog.resolve(selector: "Ubuntu@Noble").selector, "ubuntu@24.04")
        XCTAssertEqual(try catalog.resolve(selector: "ubuntu@lts").selector, "ubuntu@24.04")
    }

    func testUnknownSelectorThrowsHelpfulError() throws {
        let catalog = try Catalog.loadEmbedded()
        XCTAssertThrowsError(try catalog.resolve(selector: "mint")) { error in
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

        let allRows = catalog.listRows(includeExperimental: true)
        XCTAssertEqual(
            allRows.map(\.name), ["almalinux", "debian", "fedora", "kali", "opensuse", "ubuntu"])
    }

    func testKnownDistroIconsResolveByAliases() throws {
        XCTAssertEqual(DistroIconCatalog.icon(for: "ubuntu")?.kind, .svg)
        XCTAssertEqual(DistroIconCatalog.icon(for: "ubuntu")?.backgroundHex, "E95420")
        XCTAssertEqual(DistroIconCatalog.icon(for: "almalinux")?.backgroundHex, "000000")
        XCTAssertEqual(DistroIconCatalog.displayName(for: "alma"), "AlmaLinux")
        XCTAssertEqual(DistroIconCatalog.displayName(for: "ubuntu"), "Ubuntu")
        XCTAssertEqual(
            DistroIconCatalog.icon(for: "arch")?.url, "https://cdn.simpleicons.org/archlinux")
        XCTAssertEqual(DistroIconCatalog.displayName(for: "arch"), "Arch Linux")
        XCTAssertEqual(
            DistroIconCatalog.icon(for: "archlinux")?.url, "https://cdn.simpleicons.org/archlinux")
        XCTAssertEqual(DistroIconCatalog.icon(for: "fedora")?.kind, .svg)
        XCTAssertEqual(DistroIconCatalog.icon(for: "fedora")?.backgroundHex, "51A2DA")
        XCTAssertEqual(DistroIconCatalog.displayName(for: "fedora"), "Fedora")
        XCTAssertEqual(DistroIconCatalog.displayName(for: "debian"), "Debian GNU/Linux")
        XCTAssertEqual(DistroIconCatalog.displayName(for: "kali-linux"), "Kali Linux")
        XCTAssertEqual(DistroIconCatalog.displayName(for: "mint"), "Linux Mint")
        XCTAssertEqual(DistroIconCatalog.displayName(for: "opensuse-tumbleweed"), "openSUSE")
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
