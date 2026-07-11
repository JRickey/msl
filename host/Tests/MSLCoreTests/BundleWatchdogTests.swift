import Foundation
import XCTest

@testable import MSLCore

final class BundleWatchdogTests: XCTestCase {
    func testDevBuildNeverArms() {
        let watchdog = BundleWatchdog(bundlePath: nil)
        var misses = 0
        for _ in 0..<10 {
            let decision = watchdog.decide(missCount: misses) { _ in false }
            XCTAssertFalse(decision.act)
            XCTAssertEqual(decision.missCount, 0)
            misses = decision.missCount
        }
    }

    func testPresentBundleNeverActs() {
        let watchdog = BundleWatchdog(bundlePath: "/Applications/msl.app")
        var misses = 0
        for _ in 0..<10 {
            let decision = watchdog.decide(missCount: misses) { _ in true }
            XCTAssertFalse(decision.act)
            XCTAssertEqual(decision.missCount, 0)
            misses = decision.missCount
        }
    }

    func testThreeConsecutiveMissesActsOnThird() {
        let watchdog = BundleWatchdog(bundlePath: "/Applications/msl.app")
        let first = watchdog.decide(missCount: 0) { _ in false }
        XCTAssertFalse(first.act)
        XCTAssertEqual(first.missCount, 1)
        let second = watchdog.decide(missCount: first.missCount) { _ in false }
        XCTAssertFalse(second.act)
        XCTAssertEqual(second.missCount, 2)
        let third = watchdog.decide(missCount: second.missCount) { _ in false }
        XCTAssertTrue(third.act)
        XCTAssertEqual(third.missCount, 3)
    }

    func testPresentObservationResetsCounter() {
        let watchdog = BundleWatchdog(bundlePath: "/Applications/msl.app")
        var decision = watchdog.decide(missCount: 0) { _ in false }
        XCTAssertEqual(decision.missCount, 1)
        decision = watchdog.decide(missCount: decision.missCount) { _ in false }
        XCTAssertEqual(decision.missCount, 2)
        decision = watchdog.decide(missCount: decision.missCount) { _ in true }
        XCTAssertFalse(decision.act)
        XCTAssertEqual(decision.missCount, 0)
        decision = watchdog.decide(missCount: decision.missCount) { _ in false }
        XCTAssertEqual(decision.missCount, 1)
        decision = watchdog.decide(missCount: decision.missCount) { _ in false }
        XCTAssertFalse(decision.act)
        XCTAssertEqual(decision.missCount, 2)
    }

    func testResolveBundlePathFindsAppAncestor() {
        let path = BundleWatchdog.resolveBundlePath(
            executablePath: "/Applications/msl.app/Contents/MacOS/msl")
        XCTAssertEqual(path, "/Applications/msl.app")
    }

    func testResolveBundlePathNilForDevTree() {
        XCTAssertNil(
            BundleWatchdog.resolveBundlePath(executablePath: "/Users/x/dev/msl/.build/release/msl"))
        XCTAssertNil(BundleWatchdog.resolveBundlePath(executablePath: ""))
        XCTAssertNil(BundleWatchdog.resolveBundlePath(executablePath: nil))
    }

    func testResolveBundlePathNilWhenAppNotFollowedByContentsMacOS() {
        XCTAssertNil(
            BundleWatchdog.resolveBundlePath(executablePath: "/Users/x/code/foo.app/src/msl"))
        XCTAssertNil(
            BundleWatchdog.resolveBundlePath(executablePath: "/Users/x/foo.app/Contents/msl"))
    }

    func testResolveBundlePathDisarmsWatchdogForFalseAppAncestor() {
        let path = BundleWatchdog.resolveBundlePath(
            executablePath: "/Users/x/code/foo.app/src/msl")
        let watchdog = BundleWatchdog(bundlePath: path)
        let decision = watchdog.decide(missCount: 2) { _ in false }
        XCTAssertFalse(decision.act)
        XCTAssertEqual(decision.missCount, 0)
    }
}
