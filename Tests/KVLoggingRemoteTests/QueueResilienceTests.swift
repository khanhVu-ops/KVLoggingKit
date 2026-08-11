import Foundation
import KVLoggingKit
import KVLoggingSecurity
import XCTest
@testable import KVLoggingRemote

private actor RecordingTransport: LogTransport {
    private(set) var attempts: [[LogEvent]] = []
    private var failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func setFailure(_ failure: (any Error)?) {
        self.failure = failure
    }

    func send(_ events: [LogEvent]) async throws {
        attempts.append(events)
        if let failure { throw failure }
    }

    var attemptCount: Int { attempts.count }
}

final class QueueResilienceTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvqueue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func event(_ message: String) -> LogEvent {
        LogEvent(level: .info, message: message)
    }

    /// A single unreadable file used to stall the replay loop forever, which
    /// left every batch behind it undeliverable.
    func testCorruptQueueFileIsDiscardedInsteadOfBlockingTheQueue() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = try DiskLogBatchQueue(directory: directory)
        try await queue.enqueue([event("good")])

        // Land a corrupt entry that sorts first, since names are timestamped.
        let corrupt = directory.appendingPathComponent("00000000000000000001-\(UUID().uuidString).kvbatch")
        try Data("not a batch".utf8).write(to: corrupt)

        let batch = try await queue.oldest()

        XCTAssertEqual(batch?.events.map(\.message), ["good"])
        let remaining = try await queue.count()
        let discarded = await queue.discardedBatchCount
        XCTAssertEqual(remaining, 1)
        XCTAssertEqual(discarded, 1)
    }

    func testTrimDropsOldestBatchesBeyondTheLimit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = try DiskLogBatchQueue(directory: directory)
        for index in 0..<5 {
            try await queue.enqueue([event("batch-\(index)")])
        }

        try await queue.trim(to: 2)

        let remaining = try await queue.count()
        XCTAssertEqual(remaining, 2)
        let oldest = try await queue.oldest()
        XCTAssertEqual(oldest?.events.map(\.message), ["batch-3"])
    }

    func testNonRetryableStatusIsNotRetriedAndNotQueued() async throws {
        let transport = RecordingTransport(
            failure: HTTPLogTransportError.unacceptableStatusCode(401)
        )
        let queue = MemoryLogBatchQueue()
        let destination = RemoteBatchDestination(
            transport: transport,
            queue: queue,
            policy: .init(maxBatchSize: 1, flushInterval: 0, retry: .init(maximumAttempts: 4, initialDelay: 0))
        )

        try await destination.write([event("a")])
        try await destination.flush()

        let attempts = await transport.attemptCount
        let queued = try await queue.count()
        XCTAssertEqual(attempts, 1, "401 must not be retried")
        XCTAssertEqual(queued, 0, "a rejected key never succeeds, so nothing should be parked")
    }

    func testRetryableStatusIsRetriedThenQueued() async throws {
        let transport = RecordingTransport(
            failure: HTTPLogTransportError.unacceptableStatusCode(503)
        )
        let queue = MemoryLogBatchQueue()
        let destination = RemoteBatchDestination(
            transport: transport,
            queue: queue,
            policy: .init(maxBatchSize: 1, flushInterval: 0, retry: .init(maximumAttempts: 3, initialDelay: 0))
        )

        try await destination.write([event("a")])

        let attemptsAfterWrite = await transport.attemptCount
        let queuedAfterWrite = try await queue.count()
        XCTAssertEqual(attemptsAfterWrite, 3, "503 is retried up to the attempt limit")
        XCTAssertEqual(queuedAfterWrite, 1, "then parked for a later replay")

        try await destination.flush()

        let attemptsAfterFlush = await transport.attemptCount
        let queuedAfterFlush = try await queue.count()
        XCTAssertEqual(attemptsAfterFlush, 6, "flush replays the queued batch")
        XCTAssertEqual(queuedAfterFlush, 1, "still failing, so it stays queued")
    }

    func testTooManyRequestsIsTreatedAsRetryable() {
        XCTAssertTrue(HTTPLogTransportError.unacceptableStatusCode(429).isRetryable)
        XCTAssertTrue(HTTPLogTransportError.unacceptableStatusCode(408).isRetryable)
        XCTAssertFalse(HTTPLogTransportError.unacceptableStatusCode(400).isRetryable)
        XCTAssertFalse(HTTPLogTransportError.unacceptableStatusCode(403).isRetryable)
        XCTAssertTrue(HTTPLogTransportError.unacceptableStatusCode(500).isRetryable)
    }

    func testQueueIsCappedSoAFailingEndpointCannotFillTheDisk() async throws {
        let transport = RecordingTransport(
            failure: HTTPLogTransportError.unacceptableStatusCode(503)
        )
        let queue = MemoryLogBatchQueue()
        let destination = RemoteBatchDestination(
            transport: transport,
            queue: queue,
            policy: .init(
                maxBatchSize: 1,
                flushInterval: 0,
                retry: .init(maximumAttempts: 1, initialDelay: 0),
                maxQueuedBatches: 3
            )
        )

        for index in 0..<10 {
            try await destination.write([event("event-\(index)")])
        }
        try await destination.flush()

        let queued = try await queue.count()
        XCTAssertEqual(queued, 3)
    }

    func testMessagesAreScrubbedBeforeLeavingTheDevice() async throws {
        let transport = RecordingTransport()
        let destination = RemoteBatchDestination(
            transport: transport,
            queue: MemoryLogBatchQueue(),
            policy: .init(maxBatchSize: 1, flushInterval: 0)
        )

        try await destination.write([
            LogEvent(
                level: .info,
                message: "welcome person@example.com",
                metadata: ["email": .private("person@example.com")]
            )
        ])

        let attempts = await transport.attempts
        let sent = try XCTUnwrap(attempts.first?.first)
        XCTAssertFalse(sent.message.contains("person@example.com"))
        XCTAssertEqual(sent.metadata["email"]?.value, .string("<redacted>"))
    }
}
