import Foundation
import XCTest
@testable import KVLoggingKit

final class ImmediateLogDestinationTests: XCTestCase {
    /// Records what arrives through each path, and on which thread.
    final class SpyDestination: ImmediateLogDestination, @unchecked Sendable {
        private let lock = NSLock()
        private var _immediate: [LogEvent] = []
        private var _batched: [LogEvent] = []
        private var _threads: [Thread] = []
        private var _flushCount = 0

        let writesImmediately: Bool

        init(writesImmediately: Bool = true) {
            self.writesImmediately = writesImmediately
        }

        func writeImmediately(_ event: LogEvent) {
            lock.withLock {
                _immediate.append(event)
                _threads.append(Thread.current)
            }
        }

        func write(_ events: [LogEvent]) async throws {
            lock.withLock { _batched.append(contentsOf: events) }
        }

        func flush() async throws {
            lock.withLock { _flushCount += 1 }
        }

        var immediate: [LogEvent] { lock.withLock { _immediate } }
        var batched: [LogEvent] { lock.withLock { _batched } }
        var threads: [Thread] { lock.withLock { _threads } }
        var flushCount: Int { lock.withLock { _flushCount } }
    }

    actor RecordingDestination: LogDestination {
        private(set) var events: [LogEvent] = []

        func write(_ events: [LogEvent]) async throws {
            self.events.append(contentsOf: events)
        }
    }

    /// Only implements the async requirement, like a processor written against 1.1.0.
    struct AsyncOnlyProcessor: LogProcessor {
        func process(_ event: LogEvent) async -> LogEvent? {
            event.replacing(message: event.message + " [async]")
        }
    }

    struct DropDebugProcessor: SynchronousLogProcessor {
        func processSynchronously(_ event: LogEvent) -> LogEvent? {
            event.level == .debug ? nil : event
        }
    }

    /// Counts invocations, to prove the chain runs once per event.
    final class CountingProcessor: SynchronousLogProcessor, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }

        func processSynchronously(_ event: LogEvent) -> LogEvent? {
            lock.withLock { _count += 1 }
            return event
        }
    }

    func testWritesBeforeTheLogCallReturnsOnTheCallingThread() {
        let spy = SpyDestination()
        let client = LogClient(destinations: [spy])

        client.info("now")

        // No flush, no await: it must already be there.
        XCTAssertEqual(spy.immediate.map(\.message), ["now"])
        XCTAssertTrue(spy.threads.first === Thread.current)
    }

    func testRunsTheProcessorChainBeforeAnImmediateWrite() {
        let spy = SpyDestination()
        let client = LogClient(
            configuration: .init(processors: [
                StaticContextProcessor(metadata: ["build": .public("42")]),
                PrivacyProcessor.standard,
                DropDebugProcessor()
            ]),
            destinations: [spy]
        )

        client.debug("dropped")
        client.info("Login for kv@example.com")

        let events = spy.immediate
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(try XCTUnwrap(events.first).message.contains("kv@example.com"))
        XCTAssertEqual(events.first?.metadata["build"]?.value.stringValue, "42")
    }

    func testBatchedDestinationsGetTheSameEventProcessedOnce() async {
        let spy = SpyDestination()
        let recorder = RecordingDestination()
        let counter = CountingProcessor()
        let client = LogClient(
            configuration: .init(processors: [counter, PrivacyProcessor.standard]),
            destinations: [spy, recorder]
        )

        client.info("token for kv@example.com")
        client.info("second")
        await client.flush()

        let batched = await recorder.events
        XCTAssertEqual(batched.map(\.message), spy.immediate.map(\.message))
        XCTAssertEqual(batched.first?.id, spy.immediate.first?.id)
        XCTAssertEqual(counter.count, 2)
        // Never both paths for the same destination.
        XCTAssertTrue(spy.batched.isEmpty)
        // It is still flushed with the rest.
        XCTAssertEqual(spy.flushCount, 1)
    }

    func testFallsBackToBatchingWhenAProcessorIsAsyncOnly() async {
        let spy = SpyDestination()
        let client = LogClient(
            configuration: .init(processors: [AsyncOnlyProcessor()]),
            destinations: [spy]
        )

        client.info("late")
        XCTAssertTrue(spy.immediate.isEmpty, "must not bypass a processor it cannot run")

        await client.flush()
        XCTAssertEqual(spy.batched.map(\.message), ["late [async]"])
    }

    func testOptingOutKeepsTheDestinationBatched() async {
        let spy = SpyDestination(writesImmediately: false)
        let client = LogClient(destinations: [spy])

        client.info("batched")
        XCTAssertTrue(spy.immediate.isEmpty)

        await client.flush()
        XCTAssertEqual(spy.batched.map(\.message), ["batched"])
    }

    func testBuiltInProcessorsAreSynchronous() {
        let processors: [any LogProcessor] = [
            PrivacyProcessor.standard,
            DeviceContextProcessor(),
            StaticContextProcessor(metadata: [:])
        ]
        for processor in processors {
            XCTAssertTrue(processor is any SynchronousLogProcessor, "\(type(of: processor))")
        }
    }
}
