import Foundation
import XCTest
@testable import KVLoggingSecurity

final class LogEncryptionTests: XCTestCase {
    func testAESGCMRoundTrip() throws {
        let provider = try StaticLogEncryptionKeyProvider(
            keyData: Data(repeating: 7, count: 32)
        )
        let cipher = AESGCMLogCipher(keyProvider: provider)
        let plaintext = Data("private log".utf8)

        let ciphertext = try cipher.seal(plaintext)
        let decrypted = try cipher.open(ciphertext)

        XCTAssertEqual(decrypted, plaintext)
        XCTAssertNotEqual(ciphertext, plaintext)
    }

    func testAESGCMUsesRandomNonce() throws {
        let provider = try StaticLogEncryptionKeyProvider(
            keyData: Data(repeating: 9, count: 32)
        )
        let cipher = AESGCMLogCipher(keyProvider: provider)
        let plaintext = Data("same event".utf8)

        XCTAssertNotEqual(try cipher.seal(plaintext), try cipher.seal(plaintext))
    }

    func testTamperedCiphertextThrows() throws {
        let provider = try StaticLogEncryptionKeyProvider(
            keyData: Data(repeating: 3, count: 32)
        )
        let cipher = AESGCMLogCipher(keyProvider: provider)
        var ciphertext = try cipher.seal(Data("event".utf8))
        ciphertext[ciphertext.startIndex] ^= 0xFF

        XCTAssertThrowsError(try cipher.open(ciphertext))
    }

    func testStaticKeyRejectsInvalidLength() {
        XCTAssertThrowsError(
            try StaticLogEncryptionKeyProvider(keyData: Data(repeating: 1, count: 16))
        )
    }

    func testNoEncryptionCipherReturnsOriginalData() throws {
        let cipher = NoEncryptionCipher()
        let data = Data("plain".utf8)

        XCTAssertEqual(try cipher.seal(data), data)
        XCTAssertEqual(try cipher.open(data), data)
    }
}
