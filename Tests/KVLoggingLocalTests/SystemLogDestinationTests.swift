import Foundation
import XCTest
import KVLoggingKit
@testable import KVLoggingLocal

final class SystemLogDestinationTests: XCTestCase {
    func testWritesImmediatelyByDefault() {
        let destination = SystemLogDestination(subsystem: "KVLoggingKit.Tests")

        XCTAssertEqual(destination.mode, .immediate)
        XCTAssertTrue(destination.writesImmediately)
    }

    func testBatchedModeOptsOut() {
        let destination = SystemLogDestination(subsystem: "KVLoggingKit.Tests", mode: .batched)

        XCTAssertFalse(destination.writesImmediately)
    }

    /// The immediate path runs on whatever thread logs, so it has to tolerate
    /// many at once, including first use of the same category.
    func testConcurrentImmediateWritesAreSafe() {
        let destination = SystemLogDestination(subsystem: "KVLoggingKit.Tests")

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            destination.writeImmediately(
                LogEvent(
                    level: .debug,
                    message: "concurrent-\(index)",
                    category: "category-\(index % 7)",
                    metadata: ["email": .private("kv@example.com")]
                )
            )
        }
    }

    func testClientUsesTheImmediatePathForTheDefaultDestination() async {
        let destination = SystemLogDestination(subsystem: "KVLoggingKit.Tests")
        let client = LogClient(
            configuration: .init(processors: [PrivacyProcessor.standard, DeviceContextProcessor()]),
            destinations: [destination]
        )

        client.info("immediate")
        await client.flush()
    }
}
