import XCTest
import KVLoggingKit
@testable import KVLoggingTesting

final class InMemoryLogDestinationTests: XCTestCase {
    func testSnapshotAndClear() async {
        let destination = InMemoryLogDestination()
        let client = LogClient(destinations: [destination])

        client.info("first")
        client.error("second")
        await client.flush()

        let snapshot = await destination.snapshot()
        XCTAssertEqual(snapshot.map(\.message), ["first", "second"])

        await destination.clear()
        let cleared = await destination.snapshot()
        XCTAssertTrue(cleared.isEmpty)
    }
}
