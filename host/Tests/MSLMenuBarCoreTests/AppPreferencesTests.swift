import Foundation
import XCTest

@testable import MSLMenuBarCore

final class AppPreferencesTests: XCTestCase {
    func testMissingKeyDefaultsMenuBarItemOn() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let preferences = fixture.store.load()

        XCTAssertTrue(preferences.showMenuBarItem)
        XCTAssertNil(fixture.defaults.object(forKey: AppPreferencesStore.showMenuBarItemKey))
    }

    func testPersistedOffAndOnRoundTrip() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        fixture.store.save(AppPreferences(showMenuBarItem: false))
        XCTAssertFalse(fixture.store.load().showMenuBarItem)
        fixture.store.save(AppPreferences(showMenuBarItem: true))
        XCTAssertTrue(fixture.store.load().showMenuBarItem)
    }

    func testVisibilityPolicyDisposesAndRecreatesOnlyTheStatusItem() {
        XCTAssertEqual(
            StatusItemPreferencePolicy.action(
                showMenuBarItem: false,
                hasStatusController: true
            ),
            .dispose
        )
        XCTAssertEqual(
            StatusItemPreferencePolicy.action(
                showMenuBarItem: false,
                hasStatusController: false
            ),
            .none
        )
        XCTAssertEqual(
            StatusItemPreferencePolicy.action(
                showMenuBarItem: true,
                hasStatusController: false
            ),
            .create
        )
    }

    private func makeFixture() throws -> PreferencesFixture {
        let suiteName = "dev.msl.tests.preferences.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PreferencesFixtureError.cannotCreateDefaults
        }
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertNil(defaults.object(forKey: AppPreferencesStore.showMenuBarItemKey))
        return PreferencesFixture(
            suiteName: suiteName,
            defaults: defaults,
            store: AppPreferencesStore(defaults: defaults)
        )
    }
}

private struct PreferencesFixture {
    let suiteName: String
    let defaults: UserDefaults
    let store: AppPreferencesStore

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private enum PreferencesFixtureError: Error {
    case cannotCreateDefaults
}
