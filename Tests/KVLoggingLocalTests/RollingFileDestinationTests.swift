import Foundation
import XCTest
import KVLoggingKit
import KVLoggingSecurity
@testable import KVLoggingLocal

final class RollingFileDestinationTests: XCTestCase {
    func testWritesPlainJSONLines() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try RollingFileDestination(
            directory: directory,
            policy: .init(protection: .none)
        )

        try await destination.write([
            LogEvent(level: .info, message: "profile loaded")
        ])

        let files = await destination.logFiles()
        let file = try XCTUnwrap(files.first)
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(contents.contains("profile loaded"))
        XCTAssertTrue(contents.hasSuffix("\n"))
    }

    func testEncryptedOutputDoesNotContainPlaintext() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try StaticLogEncryptionKeyProvider(
            keyData: Data(repeating: 4, count: 32)
        )
        let destination = try RollingFileDestination(
            directory: directory,
            policy: .init(protection: .encrypted(AESGCMLogCipher(keyProvider: key)))
        )

        try await destination.write([
            LogEvent(level: .info, message: "private profile value")
        ])

        let files = await destination.logFiles()
        let file = try XCTUnwrap(files.first)
        let contents = try Data(contentsOf: file)
        XCTAssertNil(String(data: contents, encoding: .utf8)?.range(of: "private profile value"))
    }

    func testRotationCapsRetainedFiles() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try RollingFileDestination(
            directory: directory,
            policy: .init(
                maxFileSize: 180,
                maxFileCount: 2,
                protection: .none
            )
        )

        for index in 0..<8 {
            try await destination.write([
                LogEvent(level: .info, message: "event-\(index)-xxxxxxxxxxxxxxxxxxxxxxxx")
            ])
        }

        let files = await destination.logFiles()
        XCTAssertLessThanOrEqual(files.count, 2)
    }

    func testExportCopiesRetainedFiles() async throws {
        let directory = makeTemporaryDirectory()
        let exportDirectory = makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: exportDirectory)
        }
        let destination = try RollingFileDestination(directory: directory)
        try await destination.write([LogEvent(level: .info, message: "export me")])

        let result = try await destination.export(to: exportDirectory)
        let exportedFiles = try FileManager.default.contentsOfDirectory(
            at: result,
            includingPropertiesForKeys: nil
        )

        XCTAssertEqual(exportedFiles.count, 1)
    }

    func testWriteRemovesExpiredFiles() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let expiredFile = directory.appendingPathComponent("expired.kvlog")
        try Data("old".utf8).write(to: expiredFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)],
            ofItemAtPath: expiredFile.path
        )
        let destination = try RollingFileDestination(
            directory: directory,
            policy: .init(retentionDays: 1)
        )

        try await destination.write([LogEvent(level: .info, message: "new")])

        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredFile.path))
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KVLoggingLocalTests-\(UUID().uuidString)", isDirectory: true)
    }
}
