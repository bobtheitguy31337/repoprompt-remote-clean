import Foundation
import Security

enum RemoteIrohIdentityStoreError: Error, Equatable {
    case keychain(OSStatus)
    case randomGenerationFailed(OSStatus)
    case invalidGeneratedIdentityLength(Int)
}

struct RemoteIrohIdentity: Equatable {
    enum Origin: Equatable {
        case loaded
        case created
        case replacedCorruptValue
    }

    let secret: Data
    let origin: Origin
}

/// Owns the stable Iroh endpoint secret on iOS. Swift persists the exact
/// 32-byte value and passes it to Rust only when an endpoint is started.
final class RemoteIrohIdentityStore {
    static let service = "com.repoprompt.remote.iroh-identity.v1"
    static let account = "iroh-endpoint"
    static let byteCount = 32

    private let read: () throws -> Data?
    private let write: (Data) throws -> Void
    private let deleteStored: () throws -> Void
    private let generate: () throws -> Data

    convenience init() {
        self.init(
            read: Self.readKeychain,
            write: Self.writeKeychain,
            delete: Self.deleteKeychain,
            generate: Self.generateRandomSecret
        )
    }

    init(
        read: @escaping () throws -> Data?,
        write: @escaping (Data) throws -> Void,
        delete: @escaping () throws -> Void = {},
        generate: @escaping () throws -> Data
    ) {
        self.read = read
        self.write = write
        deleteStored = delete
        self.generate = generate
    }

    func delete() throws {
        try deleteStored()
    }

    func loadOrCreate() throws -> RemoteIrohIdentity {
        let stored = try read()
        if let stored, stored.count == Self.byteCount {
            return RemoteIrohIdentity(secret: stored, origin: .loaded)
        }

        let generated = try generate()
        guard generated.count == Self.byteCount else {
            throw RemoteIrohIdentityStoreError.invalidGeneratedIdentityLength(generated.count)
        }
        try write(generated)
        return RemoteIrohIdentity(
            secret: generated,
            origin: stored == nil ? .created : .replacedCorruptValue
        )
    }

    private static func readKeychain() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw RemoteIrohIdentityStoreError.keychain(status)
        }
        return result as? Data
    }

    private static func writeKeychain(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw RemoteIrohIdentityStoreError.keychain(updateStatus)
        }
        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RemoteIrohIdentityStoreError.keychain(addStatus)
        }
    }

    private static func deleteKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteIrohIdentityStoreError.keychain(status)
        }
    }

    private static func generateRandomSecret() throws -> Data {
        var bytes = Data(count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw RemoteIrohIdentityStoreError.randomGenerationFailed(status)
        }
        return bytes
    }
}
