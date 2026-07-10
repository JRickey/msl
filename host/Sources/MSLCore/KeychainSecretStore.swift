import Darwin
import Foundation
import Security

public struct SecretItemRecord: Codable, Sendable, Equatable {
    public let id: String
    public let collection: String
    public let label: String
    public let attributes: [String: String]
    public let created: UInt64
    public let modified: UInt64

    public init(
        id: String, collection: String, label: String, attributes: [String: String],
        created: UInt64, modified: UInt64
    ) {
        self.id = id
        self.collection = collection
        self.label = label
        self.attributes = attributes
        self.created = created
        self.modified = modified
    }
}

public protocol SecretByteStore: Sendable {
    func store(service: String, account: String, secret: Data) throws
    func read(service: String, account: String) throws -> Data
    func delete(service: String, account: String) throws
}

public struct SecurityKeychainBackend: SecretByteStore {
    public init() {}

    /// Update-then-add; a concurrent writer can win the gap between the two, so
    /// `errSecDuplicateItem` folds back into a single retried update.
    public func store(service: String, account: String, secret: Data) throws {
        let query = baseQuery(service: service, account: account)
        let attrs = [kSecValueData: secret] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, attrs)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Self.mapStatus(status) }
        var add = query
        add[kSecValueData] = secret
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else { throw Self.mapStatus(added) }
        let retried = SecItemUpdate(query as CFDictionary, attrs)
        guard retried == errSecSuccess else { throw Self.mapStatus(retried) }
    }

    public func read(service: String, account: String) throws -> Data {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Self.mapStatus(status) }
        guard let data = result as? Data else {
            throw AuthProxyError.backend("keychain item did not return data")
        }
        return data
    }

    public func delete(service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.mapStatus(status)
        }
    }

    /// Keychain statuses the Secret Service surface must distinguish; anything
    /// else is an opaque backend failure the guest reports as `internal`.
    static func mapStatus(_ status: OSStatus) -> AuthProxyError {
        assert(status != errSecSuccess, "success is not an error")
        let message =
            SecCopyErrorMessageString(status, nil) as String?
            ?? "keychain status \(status)"
        switch status {
        case errSecItemNotFound:
            return .notFound(message)
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecNotAvailable:
            return .locked(message)
        case errSecUserCanceled, errSecAuthFailed:
            return .denied(message)
        default:
            return .backend(message)
        }
    }

    private func baseQuery(service: String, account: String) -> [CFString: Any] {
        precondition(!service.isEmpty, "keychain service must not be empty")
        precondition(!account.isEmpty, "keychain account must not be empty")
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }
}

public enum KeychainSecretLimits {
    public static let defaultCollection = "login"
    public static let maxSecretBytes = 1024 * 1024
    public static let maxAttributes = 64
    public static let maxAttributeBytes = 512
    public static let maxLabelBytes = 512
}

/// Secret bytes live in Keychain; non-secret metadata lives in `secrets.json`.
/// Every mutation runs the whole read-modify-write of that file under `lock`,
/// because one store instance is shared by all auth connection threads.
public struct KeychainSecretStore: Sendable {
    private let url: URL
    private let bytes: any SecretByteStore
    private let clock: @Sendable () -> UInt64
    private let lock = NSLock()

    public init(
        url: URL, bytes: any SecretByteStore,
        clock: @escaping @Sendable () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970)
        }
    ) {
        self.url = url
        self.bytes = bytes
        self.clock = clock
    }

    public func create(
        label: String, attributes: [String: String], secret: Data
    ) throws -> SecretItemRecord {
        try validate(label: label, attributes: attributes, secret: secret)
        assert(secret.count <= KeychainSecretLimits.maxSecretBytes, "validate bounds the secret")
        return try withMetadata { file in
            let now = clock()
            let record = SecretItemRecord(
                id: Token.generate(), collection: KeychainSecretLimits.defaultCollection,
                label: label, attributes: attributes, created: now, modified: now)
            try bytes.store(
                service: service(record.collection), account: record.id, secret: secret)
            file.items.append(record)
            return record
        }
    }

    public func search(attributes: [String: String]) throws -> [SecretItemRecord] {
        try validateAttributes(attributes)
        assert(attributes.count <= KeychainSecretLimits.maxAttributes, "validate bounds the query")
        let items = try withMetadata { file in file.items }
        return items.filter { item in
            attributes.allSatisfy { key, value in item.attributes[key] == value }
        }
    }

    public func secret(id: String) throws -> Data {
        guard !id.isEmpty else { throw AuthProxyError.badRequest("secret id is empty") }
        let record = try requireRecord(id: id)
        assert(!record.collection.isEmpty, "stored records carry a collection")
        return try bytes.read(service: service(record.collection), account: record.id)
    }

    public func update(id: String, secret: Data) throws -> SecretItemRecord {
        guard !id.isEmpty else { throw AuthProxyError.badRequest("secret id is empty") }
        guard secret.count <= KeychainSecretLimits.maxSecretBytes else {
            throw AuthProxyError.tooLarge
        }
        return try withMetadata { file in
            guard let index = file.items.firstIndex(where: { $0.id == id }) else {
                throw AuthProxyError.notFound("secret item not found")
            }
            let current = file.items[index]
            let updated = SecretItemRecord(
                id: current.id, collection: current.collection, label: current.label,
                attributes: current.attributes, created: current.created, modified: clock())
            try bytes.store(
                service: service(current.collection), account: current.id, secret: secret)
            file.items[index] = updated
            return updated
        }
    }

    public func delete(id: String) throws {
        guard !id.isEmpty else { throw AuthProxyError.badRequest("secret id is empty") }
        try withMetadata { file in
            guard let index = file.items.firstIndex(where: { $0.id == id }) else { return }
            let record = file.items.remove(at: index)
            assert(record.id == id, "removed the record we located")
            try bytes.delete(service: service(record.collection), account: record.id)
        }
    }

    public func record(id: String) throws -> SecretItemRecord {
        guard !id.isEmpty else { throw AuthProxyError.badRequest("secret id is empty") }
        return try requireRecord(id: id)
    }

    private func requireRecord(id: String) throws -> SecretItemRecord {
        assert(!id.isEmpty, "callers reject an empty id")
        let items = try withMetadata { file in file.items }
        guard let record = items.first(where: { $0.id == id }) else {
            throw AuthProxyError.notFound("secret item not found")
        }
        return record
    }

    /// Serializes load -> mutate -> save. `body` sees a mutable snapshot; the
    /// file is rewritten only when it changed, so reads take no write path.
    private func withMetadata<Value>(
        _ body: (inout SecretMetadataFile) throws -> Value
    ) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        var file = try load()
        let before = file
        let value = try body(&file)
        guard file != before else { return value }
        try save(file)
        return value
    }

    private func validate(label: String, attributes: [String: String], secret: Data) throws {
        guard label.utf8.count <= KeychainSecretLimits.maxLabelBytes else {
            throw AuthProxyError.badRequest("secret label too large")
        }
        guard secret.count <= KeychainSecretLimits.maxSecretBytes else {
            throw AuthProxyError.tooLarge
        }
        try validateAttributes(attributes)
    }

    private func validateAttributes(_ attributes: [String: String]) throws {
        guard attributes.count <= KeychainSecretLimits.maxAttributes else {
            throw AuthProxyError.badRequest("too many secret attributes")
        }
        for (key, value) in attributes {
            guard !key.isEmpty, key.utf8.count <= KeychainSecretLimits.maxAttributeBytes,
                value.utf8.count <= KeychainSecretLimits.maxAttributeBytes
            else { throw AuthProxyError.badRequest("secret attribute too large") }
        }
    }

    private func service(_ collection: String) -> String {
        assert(!collection.isEmpty, "secret collection must not be empty")
        assert(collection == KeychainSecretLimits.defaultCollection, "v1 has one collection")
        return "dev.msl.secrets.\(collection)"
    }

    private func load() throws -> SecretMetadataFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return SecretMetadataFile() }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw MSLError.configuration("secret metadata is empty/truncated: \(url.path)")
        }
        let file = try JSONDecoder().decode(SecretMetadataFile.self, from: data)
        try file.validate(source: url.path)
        return file
    }

    private func save(_ file: SecretMetadataFile) throws {
        assert(file.version == 1, "only v1 metadata is written")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        assert(!data.isEmpty, "encoded metadata is never empty")
        try AuthSecureFile.write(data, to: url)
    }
}

private struct SecretMetadataFile: Codable, Sendable, Equatable {
    var version = 1
    var items: [SecretItemRecord] = []

    func validate(source: String) throws {
        guard version == 1 else {
            throw MSLError.configuration("unsupported secret metadata version in \(source)")
        }
        for item in items {
            guard item.collection == KeychainSecretLimits.defaultCollection else {
                throw MSLError.configuration("unsupported secret collection in \(source)")
            }
        }
    }
}
