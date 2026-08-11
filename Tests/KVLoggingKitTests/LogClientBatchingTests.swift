import KVLoggingTesting
import XCTest
@testable import KVLoggingKit

/// Records the shape of each `write` call so batching can be asserted.
private actor BatchRecordingDestination: LogDestination {
    private(set) var writes: [[LogEvent]] = []

    func write(_ events: [LogEvent]) async throws {
        writes.append(events)
    }

    var writeCount: Int { writes.count }
    var allEvents: [LogEvent] { writes.flatMap { $0 } }
}

/// Parks the worker inside `write` so the client's buffer is guaranteed to fill.
private actor GateDestination: LogDestination {
    private var isOpen = false

    func write(_ events: [LogEvent]) async throws {
        while !isOpen {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func open() {
        isOpen = true
    }
}

final class LogClientBatchingTests: XCTestCase {
    /// A burst used to cost one `write` per event, which meant one file open,
    /// seek, fsync, and close per log line.
    func testBurstIsCoalescedIntoFewWrites() async throws {
        let destination = BatchRecordingDestination()
        let client = LogClient(
            configuration: .init(maxBatchSize: 64, batchInterval: 0.05),
            destinations: [destination]
        )

        for index in 0..<64 {
            client.info("event-\(index)")
        }
        await client.flush()

        let writeCount = await destination.writeCount
        let events = await destination.allEvents

        XCTAssertEqual(events.count, 64)
        XCTAssertEqual(writeCount, 1, "a full batch should be one write")
        XCTAssertEqual(events.map(\.message), (0..<64).map { "event-\($0)" })
    }

    func testPartialBatchIsWrittenAfterTheInterval() async throws {
        let destination = BatchRecordingDestination()
        let client = LogClient(
            configuration: .init(maxBatchSize: 100, batchInterval: 0.05),
            destinations: [destination]
        )

        client.info("only-one")

        try await Task.sleep(nanoseconds: 400_000_000)

        let events = await destination.allEvents
        XCTAssertEqual(events.map(\.message), ["only-one"], "the debounce tick must close an open batch")
    }

    func testOrderIsPreservedAcrossBatchBoundaries() async throws {
        let destination = BatchRecordingDestination()
        let client = LogClient(
            configuration: .init(maxBatchSize: 8, batchInterval: 0.05),
            destinations: [destination]
        )

        for index in 0..<40 {
            client.info("event-\(index)")
        }
        await client.flush()

        let events = await destination.allEvents
        XCTAssertEqual(events.map(\.message), (0..<40).map { "event-\($0)" })
    }

    func testMinimumLevelCanBeRaisedAtRuntime() async throws {
        let destination = InMemoryLogDestination()
        let client = LogClient(
            configuration: .init(minimumLevel: .info),
            destinations: [destination]
        )

        client.debug("hidden")
        client.minimumLevel = .debug
        client.debug("visible")
        await client.flush()

        let events = await destination.snapshot()
        XCTAssertEqual(events.map(\.message), ["visible"])
    }

    /// Overflow only happens when the worker cannot keep up, so the destination
    /// is held open until the buffer has definitely filled. Without the gate
    /// the worker drains faster than the test can produce and nothing drops.
    func testOverflowDropsEventsAndCountsThem() async throws {
        let gate = GateDestination()
        let client = LogClient(
            configuration: .init(maxBatchSize: 1, batchInterval: 0, maximumBufferedEvents: 8),
            destinations: [gate]
        )

        client.info("blocks-the-worker")
        try await Task.sleep(nanoseconds: 200_000_000)

        for index in 0..<200 {
            client.info("event-\(index)")
        }

        XCTAssertGreaterThan(
            client.droppedEventCount,
            0,
            "a bounded buffer must report what it discarded"
        )

        await gate.open()
    }

    /// Overflow evicts the oldest queued command; if that is a pending flush,
    /// its continuation must still be resumed.
    func testFlushDoesNotHangWhenTheBufferOverflows() async throws {
        let destination = InMemoryLogDestination()
        let client = LogClient(
            configuration: .init(maxBatchSize: 1_000, batchInterval: 60, maximumBufferedEvents: 4),
            destinations: [destination]
        )

        for index in 0..<500 {
            client.info("event-\(index)")
        }

        let flushed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await client.flush()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(flushed, "flush must not deadlock when its command is evicted")
    }
}
