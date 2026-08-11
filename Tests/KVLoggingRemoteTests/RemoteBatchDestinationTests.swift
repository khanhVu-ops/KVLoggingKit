import Foundation
import XCTest
import KVLoggingKit
import KVLoggingSecurity
@testable import KVLoggingRemote

final class RemoteBatchDestinationTests: XCTestCase {
    actor RecordingTransport: LogTransport {
        private var failuresRemaining: Int
        private(set) var attempts = 0
        private(set) var batches: [[LogEvent]] = []

        init(failuresRemaining: Int = 0) {
            self.failuresRemaining = failuresRemaining
        }

        func send(_ events: [LogEvent]) async throws {
            attempts += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw SampleTransportError.offline
            }
            batches.append(events)
        }

        func setFailuresRemaining(_ value: Int) {
            failuresRemaining = value
        }

        func snapshot() -> (attempts: Int, batches: [[LogEvent]]) {
            (attempts, batches)
        }
    }

    enum SampleTransportError: Error {
        case offline
    }

    func testThresholdSendsOneSanitizedBatch() async throws {
        let transport = RecordingTransport()
        let destination = RemoteBatchDestination(
            transport: transport,
            queue: MemoryLogBatchQueue(),
            policy: .init(maxBatchSize: 2, flushInterval: 3_600)
        )

        try await destination.write([
            LogEvent(
                level: .info,
                message: "first",
                metadata: ["email": .private("person@example.com")]
            )
        ])
        let beforeThreshold = await transport.snapshot()
        XCTAssertEqual(beforeThreshold.batches.count, 0)

        try await destination.write([LogEvent(level: .info, message: "second")])

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.batches.count, 1)
        XCTAssertEqual(snapshot.batches[0].map(\.message), ["first", "second"])
        XCTAssertEqual(
            snapshot.batches[0][0].metadata["email"]?.value,
            .string("<redacted>")
        )
    }

    func testRetryStopsAfterSuccess() async throws {
        let transport = RecordingTransport(failuresRemaining: 2)
        let destination = RemoteBatchDestination(
            transport: transport,
            queue: MemoryLogBatchQueue(),
            policy: .init(
                maxBatchSize: 1,
                retry: .init(maximumAttempts: 3, initialDelay: 0, maximumDelay: 0)
            )
        )

        try await destination.write([LogEvent(level: .error, message: "retry")])

        let retrySnapshot = await transport.snapshot()
        XCTAssertEqual(retrySnapshot.attempts, 3)
    }

    func testFailedBatchIsPersistedAndReplayed() async throws {
        let transport = RecordingTransport(failuresRemaining: 1)
        let queue = MemoryLogBatchQueue()
        let destination = RemoteBatchDestination(
            transport: transport,
            queue: queue,
            policy: .init(
                maxBatchSize: 1,
                retry: .init(maximumAttempts: 1, initialDelay: 0, maximumDelay: 0)
            )
        )

        try await destination.write([LogEvent(level: .error, message: "offline")])
        let queuedCount = try await queue.count()
        XCTAssertEqual(queuedCount, 1)

        await transport.setFailuresRemaining(0)
        try await destination.flush()

        let remainingCount = try await queue.count()
        let replaySnapshot = await transport.snapshot()
        XCTAssertEqual(remainingCount, 0)
        XCTAssertEqual(replaySnapshot.batches.first?.first?.message, "offline")
    }

    func testExplicitFlushSendsSubthresholdEvents() async throws {
        let transport = RecordingTransport()
        let destination = RemoteBatchDestination(
            transport: transport,
            queue: MemoryLogBatchQueue(),
            policy: .init(maxBatchSize: 50, flushInterval: 3_600)
        )

        try await destination.write([LogEvent(level: .notice, message: "flush")])
        try await destination.flush()

        let flushSnapshot = await transport.snapshot()
        XCTAssertEqual(flushSnapshot.batches.first?.count, 1)
    }

    func testDiskQueueEncryptsAndRemovesOldestBatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KVLoggingRemoteTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try StaticLogEncryptionKeyProvider(
            keyData: Data(repeating: 8, count: 32)
        )
        let queue = try DiskLogBatchQueue(
            directory: directory,
            cipher: AESGCMLogCipher(keyProvider: key)
        )

        try await queue.enqueue([LogEvent(level: .info, message: "private queued log")])

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let data = try Data(contentsOf: try XCTUnwrap(files.first))
        XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "private queued log"))

        let batch = try await queue.oldest()
        XCTAssertEqual(batch?.events.first?.message, "private queued log")
        try await queue.remove(id: try XCTUnwrap(batch?.id))
        let finalCount = try await queue.count()
        XCTAssertEqual(finalCount, 0)
    }
}
