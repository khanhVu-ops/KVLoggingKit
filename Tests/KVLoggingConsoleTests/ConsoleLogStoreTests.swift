import KVLoggingKit
import XCTest
@testable import KVLoggingConsole

final class ConsoleLogStoreTests: XCTestCase {
    private func event(_ message: String) -> LogEvent {
        LogEvent(level: .info, message: message)
    }

    func testKeepsNewestEventsUpToTheLimit() async throws {
        let store = ConsoleLogStore(limit: 3)

        try await store.write((0..<10).map { event("event-\($0)") })

        let all = await store.all()
        XCTAssertEqual(all.map(\.message), ["event-9", "event-8", "event-7"])
    }

    func testClearEmptiesTheRing() async throws {
        let store = ConsoleLogStore(limit: 5)
        try await store.write([event("a"), event("b")])

        await store.clear()

        let count = await store.count()
        XCTAssertEqual(count, 0)
    }

    func testChangeSignalFiresImmediatelyAndOnWrite() async throws {
        let store = ConsoleLogStore(limit: 5)
        var iterator = store.changes().makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertNotNil(initial, "a new observer should render without waiting")

        try await store.write([event("a")])

        let afterWrite = await iterator.next()
        XCTAssertNotNil(afterWrite)

        let all = await store.all()
        XCTAssertEqual(all.map(\.message), ["a"])
    }
}

final class LogRingBufferTests: XCTestCase {
    func testOverwritesOldestOnceFull() {
        var buffer = LogRingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }

        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.newestFirst(), [5, 4, 3])
    }

    func testReplaceUpdatesInPlace() {
        var buffer = LogRingBuffer<String>(capacity: 4)
        for value in ["a", "b", "c"] { buffer.append(value) }

        XCTAssertTrue(buffer.replace(where: { $0 == "b" }, with: "B"))
        XCTAssertEqual(buffer.newestFirst(), ["c", "B", "a"])
    }

    func testReplaceReportsWhenTheElementWasAlreadyEvicted() {
        var buffer = LogRingBuffer<String>(capacity: 2)
        for value in ["a", "b", "c"] { buffer.append(value) }

        XCTAssertFalse(buffer.replace(where: { $0 == "a" }, with: "A"))
        XCTAssertEqual(buffer.newestFirst(), ["c", "b"])
    }

    func testRemoveAllResetsState() {
        var buffer = LogRingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.removeAll()

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.newestFirst(), [])
    }
}
