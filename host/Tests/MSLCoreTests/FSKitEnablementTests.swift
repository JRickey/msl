import Foundation
import MSLFSWire
import XCTest

@testable import MSLCore

final class FSKitEnablementPathTests: XCTestCase {
    func testPlistPathUsesFSKitSettingsGroup() {
        let path = FSKitEnablement.plistPath(homeDirectory: "/Users/tester")
        XCTAssertEqual(
            path,
            "/Users/tester/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
        )
    }
}

final class FSKitEnablementMutationTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-fskit-enable-\(UUID().uuidString)")
            .appendingPathComponent("enabledModules.plist")
    }

    private func modules(at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String])
    }

    func testEnableCreatesMissingPlist() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let changed = try FSKitEnablement.enable(at: url)
        XCTAssertTrue(changed)
        XCTAssertEqual(try modules(at: url), [FSProto.appexBundleID])
        XCTAssertTrue(try FSKitEnablement.isEnabled(at: url))
    }

    func testEnablePreservesExistingModulesAndIsIdempotent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FSKitEnablement.enable(moduleID: "com.example.other", at: url)
        XCTAssertTrue(try FSKitEnablement.enable(at: url))
        XCTAssertFalse(try FSKitEnablement.enable(at: url))
        XCTAssertEqual(try modules(at: url), ["com.example.other", FSProto.appexBundleID])
    }

    func testDisableRemovesOnlyMSLModule() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FSKitEnablement.enable(moduleID: "com.example.other", at: url)
        try FSKitEnablement.enable(at: url)
        XCTAssertTrue(try FSKitEnablement.disable(at: url))
        XCTAssertFalse(try FSKitEnablement.disable(at: url))
        XCTAssertEqual(try modules(at: url), ["com.example.other"])
    }

    func testInvalidPlistShapeThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["module": FSProto.appexBundleID], format: .xml, options: 0)
        try data.write(to: url)
        XCTAssertThrowsError(try FSKitEnablement.enable(at: url))
        XCTAssertThrowsError(try FSKitEnablement.isEnabled(at: url))
    }
}
