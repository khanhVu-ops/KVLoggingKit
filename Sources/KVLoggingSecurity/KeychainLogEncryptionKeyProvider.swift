import Foundation
import Security

public final class KeychainLogEncryptionKeyProvider: LogEncryptionKeyProvider, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String,
        account: String = "KVLoggingKit.encryption-key"
    ) {
        self.service = service
        self.account = account
    }

    public func keyData() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            guard data.count == 32 else {
                throw LogEncryptionError.invalidKeyLength
            }
            return data
        }

        guard status == errSecItemNotFound else {
            throw LogEncryptionError.keychain(status)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw LogEncryptionError.randomGeneration(randomStatus)
        }

        let data = Data(bytes)
        var addQuery = query
        addQuery.removeValue(forKey: kSecReturnData as String)
        addQuery.removeValue(forKey: kSecMatchLimit as String)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw LogEncryptionError.keychain(addStatus)
        }

        if addStatus == errSecDuplicateItem {
            return try keyData()
        }
        return data
    }
}
