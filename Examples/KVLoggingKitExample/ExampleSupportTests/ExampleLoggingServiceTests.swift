import Foundation
import XCTest
@testable import ExampleSupport

@MainActor
final class ExampleLoggingServiceTests: XCTestCase {
    func testOnlineFlushDeliversAllSampleEvents() async throws {
        let harness = try ExampleLoggingService.makeTestHarness()
        defer { try? FileManager.default.removeItem(at: harness.rootDirectory) }

        harness.service.generateSampleLogs()
        let snapshot = await harness.service.flushAndSnapshot()

        XCTAssertEqual(snapshot.deliveredEventCount, 4)
        XCTAssertEqual(snapshot.queuedBatchCount, 0)
    }

    func testOfflineBatchQueuesThenReplaysWhenOnline() async throws {
        let harness = try ExampleLoggingService.makeTestHarness()
        defer { try? FileManager.default.removeItem(at: harness.rootDirectory) }

        await harness.service.setOnline(false)
        harness.service.generateSampleLogs()
        let offline = await harness.service.flushAndSnapshot()
        XCTAssertEqual(offline.queuedBatchCount, 1)

        await harness.service.setOnline(true)
        let online = await harness.service.flushAndSnapshot()

        XCTAssertEqual(online.queuedBatchCount, 0)
        XCTAssertEqual(online.deliveredEventCount, 4)
    }
}
