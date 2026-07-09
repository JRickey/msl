import Foundation
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

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-secrets-\(UUID().uuidString)")
        return dir.appendingPathComponent("secrets.json")
    }
}

private final class MemorySecretBytes: SecretByteStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(service: String, account: String, secret: Data) throws {
        lock.lock()
        values[key(service, account)] = secret
        lock.unlock()
    }

    func read(service: String, account: String) throws -> Data {
        lock.lock()
        let value = values[key(service, account)]
        lock.unlock()
        guard let value else { throw AuthProxyError.denied("missing test secret") }
        return value
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        values[key(service, account)] = nil
        lock.unlock()
    }

    private func key(_ service: String, _ account: String) -> String {
        return service + "\u{1f}" + account
    }
}
