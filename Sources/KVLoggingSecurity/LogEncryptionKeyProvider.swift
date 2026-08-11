import Foundation

public protocol LogEncryptionKeyProvider: Sendable {
    func keyData() throws -> Data
}

public enum LogEncryptionError: Error, Equatable {
    case invalidKeyLength
    case missingCombinedCiphertext
    case keychain(OSStatus)
    case randomGeneration(OSStatus)
}

public struct StaticLogEncryptionKeyProvider: LogEncryptionKeyProvider {
    private let key: Data

    public init(keyData: Data) throws {
        guard keyData.count == 32 else {
            throw LogEncryptionError.invalidKeyLength
        }
        key = keyData
    }

    public func keyData() throws -> Data {
        key
    }
}
