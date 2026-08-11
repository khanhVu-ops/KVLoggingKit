import Foundation

public protocol LogDataCipher: Sendable {
    func seal(_ data: Data) throws -> Data
    func open(_ data: Data) throws -> Data
}

public struct NoEncryptionCipher: LogDataCipher {
    public init() {}

    public func seal(_ data: Data) throws -> Data {
        data
    }

    public func open(_ data: Data) throws -> Data {
        data
    }
}
