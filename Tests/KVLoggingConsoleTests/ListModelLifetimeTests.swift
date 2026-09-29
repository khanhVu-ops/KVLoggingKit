import KVLoggingKit
import KVLoggingNetwork
import XCTest
@testable import KVLoggingConsole

/// The observation task used to capture its model strongly, and only
/// `onDisappear` cancelled it. The model's own `deinit` cancel could never run —
/// the task was keeping it alive — so a console torn down without that callback
/// leaked the model, the task, and a store subscription for good.
@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class ListModelLifetimeTests: XCTestCase {
    func testLogListModelIsReleasedWhileObserving() async throws {
        let store = ConsoleLogStore(limit: 10)
        weak var weakModel: LogListModel?

        do {
            let model = LogListModel(store: store)
            weakModel = model
            model.startObserving()
            try await store.write([LogEvent(level: .info, message: "first")])
            try await waitUntil { model.events.count == 1 }
        }

        try await waitUntil { weakModel == nil }
        XCTAssertNil(weakModel)
    }

    func testNetworkListModelIsReleasedWhileObserving() async throws {
        let store = NetworkLogStore(limit: 10)
        weak var weakModel: NetworkListModel?

        do {
            let model = NetworkListModel(store: store)
            weakModel = model
            model.startObserving()
            // Let the task reach its first suspension inside the loop.
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        try await waitUntil { weakModel == nil }
        XCTAssertNil(weakModel)
    }

    func testStillRefreshesAfterAWriteWhileAlive() async throws {
        let store = ConsoleLogStore(limit: 10)
        let model = LogListModel(store: store)
        model.startObserving()
        defer { model.stopObserving() }

        try await store.write([LogEvent(level: .info, message: "a")])
        try await waitUntil { model.events.count == 1 }
        try await store.write([LogEvent(level: .info, message: "b")])
        try await waitUntil { model.events.count == 2 }

        XCTAssertEqual(model.events.map(\.message), ["b", "a"])
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
