import XCTest

@testable import MSLCore

final class UserWrapQuoteTests: XCTestCase {
    func testWrapsPlainArgInSingleQuotes() {
        XCTAssertEqual(UserWrap.shellQuote("hello"), "'hello'")
    }

    func testPreservesSpaces() {
        XCTAssertEqual(UserWrap.shellQuote("a b c"), "'a b c'")
    }

    func testEmptyArgBecomesEmptyQuotes() {
        XCTAssertEqual(UserWrap.shellQuote(""), "''")
    }

    func testEscapesEmbeddedSingleQuote() {
        XCTAssertEqual(UserWrap.shellQuote("it's"), "'it'\\''s'")
    }

    func testEscapesTwoAdjacentSingleQuotes() {
        XCTAssertEqual(UserWrap.shellQuote("''"), "''\\'''\\'''")
    }
}

final class UserWrapWrapTests: XCTestCase {
    func testNilArgvIsLoginShell() {
        XCTAssertEqual(
            UserWrap.wrap(user: "jack", argv: nil, cwd: "/home/jack"),
            ["/bin/su", "-l", "jack"])
    }

    func testEmptyArgvIsLoginShell() {
        XCTAssertEqual(
            UserWrap.wrap(user: "jack", argv: [], cwd: "/home/jack"),
            ["/bin/su", "-l", "jack"])
    }

    func testCommandFormPreservesArgvOrderAndCwd() {
        let result = UserWrap.wrap(user: "jack", argv: ["ls", "-la", "/tmp"], cwd: "/work")
        XCTAssertEqual(Array(result.prefix(4)), ["/bin/su", "-l", "jack", "-c"])
        XCTAssertEqual(result[4], "cd '/work' 2>/dev/null; exec 'ls' '-la' '/tmp'")
    }

    func testCommandFormQuotesArgsWithSpaces() {
        let result = UserWrap.wrap(user: "jack", argv: ["echo", "a b"], cwd: "/w")
        XCTAssertEqual(result[4], "cd '/w' 2>/dev/null; exec 'echo' 'a b'")
    }

    func testCommandFormQuotesEmbeddedSingleQuote() {
        let result = UserWrap.wrap(user: "svc", argv: ["sh", "-c", "echo it's"], cwd: "/x")
        XCTAssertEqual(result[4], "cd '/x' 2>/dev/null; exec 'sh' '-c' 'echo it'\\''s'")
    }
}

final class UserWrapCwdTests: XCTestCase {
    func testMacCwdFallsBackWithoutShare() {
        XCTAssertEqual(UserWrap.effectiveCwd("/mnt/mac/Dev/x", macShare: false), "/root")
    }

    func testMacCwdKeptWithShare() {
        XCTAssertEqual(UserWrap.effectiveCwd("/mnt/mac/Dev/x", macShare: true), "/mnt/mac/Dev/x")
    }

    func testDistroCwdKeptWithoutShare() {
        XCTAssertEqual(UserWrap.effectiveCwd("/var/log", macShare: false), "/var/log")
    }
}
