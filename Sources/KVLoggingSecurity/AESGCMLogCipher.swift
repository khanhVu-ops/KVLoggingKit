import CryptoKit
import Foundation

public struct AESGCMLogCipher: LogDataCipher {
    private let keyProvider: any LogEncryptionKeyProvider

    public init(keyProvider: any LogEncryptionKeyProvider) {
        self.keyProvider = keyProvider
    }

    public func seal(_ data: Data) throws -> Data {
        let key = SymmetricKey(data: try keyProvider.keyData())
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else {
            throw LogEncryptionError.missingCombinedCiphertext
        }
        return combined
    }

    public func open(_ data: Data) throws -> Data {
        let key = SymmetricKey(data: try keyProvider.keyData())
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}
