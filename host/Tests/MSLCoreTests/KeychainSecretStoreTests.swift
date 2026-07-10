import Foundation
import Security
import XCTest

@testable import MSLCore

final class KeychainSecretStoreTests: XCTestCase {
    func testCreateSearchReadAndDeleteKeepSecretOutOfMetadata() throws {
        let url = tempURL()
        let bytes = MemorySecretBytes()
        let store = KeychainSecretStore(url: url, bytes: bytes, clock: { 100 })
        let secret = Data("secret-value".utf8)

        let record = try store.create(
            label: "test", attributes: ["service": "msl", "username": "alice"],
            secret: secret)
        let found = try store.search(attributes: ["service": "msl"])

        XCTAssertEqual(found.map(\.id), [record.id])
        XCTAssertEqual(try store.secret(id: record.id), secret)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"username\""))
        XCTAssertFalse(json.contains("secret-value"))

        try store.delete(id: record.id)
        XCTAssertTrue(try store.search(attributes: ["service": "msl"]).isEmpty)
    }

    func testUpdateChangesSecretButPreservesMetadataShape() throws {
        let store = KeychainSecretStore(url: tempURL(), bytes: MemorySecretBytes(), clock: { 200 })
        let record = try store.create(label: "test", attributes: ["k": "v"], secret: Data([1]))

        let updated = try store.update(id: record.id, secret: Data([2, 3]))

        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.label, "test")
        XCTAssertEqual(try store.secret(id: record.id), Data([2, 3]))
    }

    func testRejectsOversizedAttributes() {
        let store = KeychainSecretStore(url: tempURL(), bytes: MemorySecretBytes())
        let big = String(repeating: "x", count: KeychainSecretLimits.maxAttributeBytes + 1)

        XCTAssertThrowsError(try store.create(label: "x", attributes: ["k": big], secret: Data()))
    }

    func testMissingItemsAreNotFoundRatherThanDenied() {
        let store = KeychainSecretStore(url: tempURL(), bytes: MemorySecretBytes())

        XCTAssertThrowsError(try store.record(id: "absent")) { error in
            XCTAssertEqual(error as? AuthProxyError, .notFound("secret item not found"))
        }
        XCTAssertThrowsError(try store.update(id: "absent", secret: Data([1]))) { error in
            XCTAssertEqual(error as? AuthProxyError, .notFound("secret item not found"))
        }
        XCTAssertThrowsError(try store.secret(id: "")) { error in
            XCTAssertEqual(error as? AuthProxyError, .badRequest("secret id is empty"))
        }
    }

    /// Metadata present with a missing Keychain item reads as not found.
    func testMetadataWithoutKeychainItemIsNotFound() throws {
        let bytes = MemorySecretBytes()
        let store = KeychainSecretStore(url: tempURL(), bytes: bytes)
        let record = try store.create(label: "x", attributes: [:], secret: Data([7]))
        bytes.forget()

        XCTAssertThrowsError(try store.secret(id: record.id)) { error in
            XCTAssertEqual(error as? AuthProxyError, .notFound("missing keychain item"))
        }
    }

    /// Concurrent creates each read-modify-write `secrets.json`; without the
    /// store lock the last writer wins and items vanish.
    func testConcurrentCreatesAllSurvive() throws {
        let url = tempURL()
        let store = KeychainSecretStore(url: url, bytes: MemorySecretBytes())
        let writers = 32

        DispatchQueue.concurrentPerform(iterations: writers) { index in
            let attributes = ["index": String(index)]
            do {
                _ = try store.create(
                    label: "item-\(index)", attributes: attributes, secret: Data([1]))
            } catch {
                XCTFail("concurrent create failed: \(error)")
            }
        }

        let all = try store.search(attributes: [:])
        XCTAssertEqual(all.count, writers)
        XCTAssertEqual(Set(all.map(\.id)).count, writers)
        for index in 0..<writers {
            XCTAssertEqual(try store.search(attributes: ["index": String(index)]).count, 1)
        }
    }

    func testMetadataFileAndDirectoryAreOwnerOnly() throws {
        let url = tempURL()
        let store = KeychainSecretStore(url: url, bytes: MemorySecretBytes())
        _ = try store.create(label: "x", attributes: [:], secret: Data([1]))

        XCTAssertEqual(try permissions(of: url.path), 0o600)
        XCTAssertEqual(try permissions(of: url.deletingLastPathComponent().path), 0o700)
    }

    func testKeychainStatusMapping() {
        XCTAssertEqual(code(errSecItemNotFound), .notFound(""))
        XCTAssertEqual(code(errSecInteractionNotAllowed), .locked(""))
        XCTAssertEqual(code(errSecInteractionRequired), .locked(""))
        XCTAssertEqual(code(errSecNotAvailable), .locked(""))
        XCTAssertEqual(code(errSecUserCanceled), .denied(""))
        XCTAssertEqual(code(errSecAuthFailed), .denied(""))
        XCTAssertEqual(code(errSecParam), .backend(""))
    }

    /// Compares only the case, since the message comes from the Security framework.
    private func code(_ status: OSStatus) -> AuthProxyError {
        switch SecurityKeychainBackend.mapStatus(status) {
        case .notFound: return .notFound("")
        case .locked: return .locked("")
        case .denied: return .denied("")
        case .backend: return .backend("")
        default: return .io("")
        }
    }

    private func permissions(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let mode = attributes[.posixPermissions] as? NSNumber else {
            throw AuthProxyError.backend("missing permissions")
        }
        return mode.intValue
    }

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-secrets-\(UUID().uuidString)")
        return dir.appendingPathComponent("secrets.json")
    }
}

final class MemorySecretBytes: SecretByteStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var locked = false

    func lockKeychain() {
        lock.lock()
        locked = true
        lock.unlock()
    }

    func forget() {
        lock.lock()
        values = [:]
        lock.unlock()
    }

    func store(service: String, account: String, secret: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if locked { throw AuthProxyError.locked("keychain is locked") }
        values[key(service, account)] = secret
    }

    func read(service: String, account: String) throws -> Data {
        lock.lock()
        let value = values[key(service, account)]
        let isLocked = locked
        lock.unlock()
        if isLocked { throw AuthProxyError.locked("keychain is locked") }
        guard let value else { throw AuthProxyError.notFound("missing keychain item") }
        return value
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if locked { throw AuthProxyError.locked("keychain is locked") }
        values[key(service, account)] = nil
    }

    private func key(_ service: String, _ account: String) -> String {
        return service + "\u{1f}" + account
    }
}
