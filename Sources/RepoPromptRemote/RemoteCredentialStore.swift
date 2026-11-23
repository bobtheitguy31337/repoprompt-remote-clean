import Foundation
import RepoPromptRemoteProtocol
import Security

struct StoredRemoteIrohBinding: Codable, Equatable {
    let expectedDesktopEndpointID: String
    let localMobileEndpointID: String
    let wireVersion: Int
    let serverAddress: RemoteIrohEndpointAddress

    init(
        expectedDesktopEndpointID: String,
        localMobileEndpointID: String,
        wireVersion: Int = RemoteWireProtocol.currentVersion,
        serverAddress: RemoteIrohEndpointAddress
    ) {
        self.expectedDesktopEndpointID = expectedDesktopEndpointID
        self.localMobileEndpointID = localMobileEndpointID
        self.wireVersion = wireVersion
        self.serverAddress = serverAddress
    }
}

struct StoredRemoteCredential: Codable, Equatable {
    let desktopInstanceID: String
    let deviceID: String
    let credential: String
    let irohBinding: StoredRemoteIrohBinding

    init(
        desktopInstanceID: String,
        deviceID: String,
        credential: String,
        irohBinding: StoredRemoteIrohBinding
    ) {
        self.desktopInstanceID = desktopInstanceID
        self.deviceID = deviceID
        self.credential = credential
        self.irohBinding = irohBinding
    }
}

enum RemoteCredentialStoreError: Error {
    case invalidKeychainData
    case keychain(OSStatus)
}

/// Keychain-backed storage for the one paired device. The credential is never
/// put in UserDefaults, snapshots, analytics, or diagnostic strings.
final class RemoteCredentialStore {
    private let service = "com.repoprompt.remote.credential"
    private let account = "paired-desktop"

    func load() throws -> StoredRemoteCredential? {
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
        guard status == errSecSuccess else { throw RemoteCredentialStoreError.keychain(status) }
        guard let data = result as? Data else { throw RemoteCredentialStoreError.invalidKeychainData }
        do {
            return try JSONDecoder().decode(StoredRemoteCredential.self, from: data)
        } catch {
            throw RemoteCredentialStoreError.invalidKeychainData
        }
    }

    func save(_ credential: StoredRemoteCredential) throws {
        let data = try JSONEncoder().encode(credential)
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
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw RemoteCredentialStoreError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw RemoteCredentialStoreError.keychain(updateStatus)
        }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteCredentialStoreError.keychain(status)
        }
    }
}
