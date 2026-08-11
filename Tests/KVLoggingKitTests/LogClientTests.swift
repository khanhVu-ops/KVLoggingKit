import XCTest
@testable import KVLoggingKit

final class LogClientTests: XCTestCase {
    actor RecordingDestination: LogDestination {
        private(set) var events: [LogEvent] = []

        func write(_ events: [LogEvent]) async throws {
            self.events.append(contentsOf: events)
        }

        func snapshot() -> [LogEvent] {
            events
        }
    }

    struct DropDebugProcessor: LogProcessor {
        func process(_ event: LogEvent) async -> LogEvent? {
            event.level == .debug ? nil : event
        }
    }

    func testMinimumLevelFiltersBeforeEnqueueing() async {
        let destination = RecordingDestination()
        let client = LogClient(
            configuration: .init(minimumLevel: .info),
            destinations: [destination]
        )

        client.debug("hidden")
        client.info("visible")
        await client.flush()

        let events = await destination.snapshot()
        XCTAssertEqual(events.map(\.message), ["visible"])
    }

    func testEventsRemainInCallOrder() async {
        let destination = RecordingDestination()
        let client = LogClient(destinations: [destination])

        for index in 0..<20 {
            client.info("event-\(index)")
        }
        await client.flush()

        let events = await destination.snapshot()
        XCTAssertEqual(events.map(\.message), (0..<20).map { "event-\($0)" })
    }

    func testProcessorCanDropAnEvent() async {
        let destination = RecordingDestination()
        let client = LogClient(
            configuration: .init(processors: [DropDebugProcessor()]),
            destinations: [destination]
        )

        client.debug("drop")
        client.warning("keep")
        await client.flush()

        let events = await destination.snapshot()
        XCTAssertEqual(events.map(\.message), ["keep"])
    }

    func testScopedLoggerMergesMetadataAndOverridesDefaults() async {
        let destination = RecordingDestination()
        let client = LogClient(destinations: [destination])
        let scoped = client.scoped(
            category: "network",
            metadata: [
                "request_id": .public("abc"),
                "attempt": .public(1)
            ]
        )

        scoped.info(
            "completed",
            metadata: ["attempt": .public(2)]
        )
        await client.flush()

        let event = await destination.snapshot().first
        XCTAssertEqual(event?.category, "network")
        XCTAssertEqual(event?.metadata["request_id"]?.value, .string("abc"))
        XCTAssertEqual(event?.metadata["attempt"]?.value, .integer(2))
    }

    func testFlushWaitsForPriorWrites() async {
        let destination = RecordingDestination()
        let client = LogClient(destinations: [destination])

        client.error("must be delivered")
        await client.flush()

        let events = await destination.snapshot()
        XCTAssertEqual(events.count, 1)
    }

    func testScopedConvenienceMethodCapturesCallerSource() async {
        let destination = RecordingDestination()
        let client = LogClient(destinations: [destination])
        let scoped = client.scoped(category: "test")

        scoped.info("source")
        await client.flush()

        let event = await destination.snapshot().first
        XCTAssertTrue(event?.source.file.hasSuffix("LogClientTests.swift") == true)
    }
}
