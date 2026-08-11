import Foundation
import KVLoggingKit
import KVLoggingTesting
import XCTest
@testable import KVLoggingNetwork

final class NetworkLogRecorderTests: XCTestCase {
    private func makeSnapshot(
        method: String = "GET",
        url: String = "https://api.example.com/v1/users?access_token=secret",
        headers: [String: String] = ["Authorization": "Bearer secret"],
        body: Data? = nil
    ) -> URLRequestSnapshot {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.allHTTPHeaderFields = headers
        request.httpBody = body
        return URLRequestSnapshot(request)
    }

    func testCompleteStoresARedactedRecord() async throws {
        let store = NetworkLogStore()
        let recorder = NetworkLogRecorder(store: store)
        let key = NetworkTaskKey(owner: self, taskIdentifier: 1)

        await recorder.complete(
            key,
            request: makeSnapshot(),
            response: .init(statusCode: 200, headers: ["Content-Type": "application/json"]),
            responseData: Data(#"{"ok":true}"#.utf8),
            error: nil,
            metrics: nil
        )

        let records = await store.all()
        let record = try XCTUnwrap(records.first)

        XCTAssertEqual(record.state, .succeeded)
        XCTAssertEqual(record.statusCode, 200)
        XCTAssertEqual(record.request.headers["Authorization"], "<redacted>")
        XCTAssertFalse(record.request.url.contains("secret"))
        XCTAssertEqual(record.response?.body.text?.contains("\"ok\""), true)
    }

    func testPendingRecordIsReplacedRatherThanDuplicated() async throws {
        let store = NetworkLogStore()
        let recorder = NetworkLogRecorder(store: store)
        let key = NetworkTaskKey(owner: self, taskIdentifier: 2)
        let snapshot = makeSnapshot()

        await recorder.begin(key, request: snapshot)
        let pending = await store.all()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.state, .pending)

        await recorder.complete(
            key,
            request: snapshot,
            response: .init(statusCode: 204, headers: [:]),
            responseData: nil,
            error: nil,
            metrics: nil
        )

        let finished = await store.all()
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.state, .succeeded)
        XCTAssertEqual(finished.first?.id, pending.first?.id)
    }

    func testEmittedEventCarriesNoHeadersOrBodies() async throws {
        let destination = InMemoryLogDestination()
        let logger = LogClient(destinations: [destination])
        let recorder = NetworkLogRecorder(store: NetworkLogStore(), logger: logger)

        await recorder.complete(
            NetworkTaskKey(owner: self, taskIdentifier: 3),
            request: makeSnapshot(method: "POST", body: Data(#"{"password":"hunter2"}"#.utf8)),
            response: .init(statusCode: 201, headers: ["Set-Cookie": "session=abc"]),
            responseData: Data(#"{"id":7}"#.utf8),
            error: nil,
            metrics: nil
        )
        await logger.flush()

        let events = await destination.snapshot()
        let event = try XCTUnwrap(events.first)

        XCTAssertEqual(event.category, "network")
        XCTAssertEqual(event.metadata["http_status"]?.value, .integer(201))
        XCTAssertEqual(event.metadata["http_host"]?.value, .string("api.example.com"))
        XCTAssertEqual(event.metadata["http_path"]?.value, .string("/v1/users"))

        let rendered = event.message + event.metadata.values.map(\.value.stringValue).joined()
        XCTAssertFalse(rendered.contains("hunter2"))
        XCTAssertFalse(rendered.contains("session=abc"))
        XCTAssertFalse(rendered.contains("id\":7"))
    }

    func testLevelReflectsStatusAndError() async throws {
        let destination = InMemoryLogDestination()
        let logger = LogClient(destinations: [destination])
        let recorder = NetworkLogRecorder(store: NetworkLogStore(), logger: logger)

        await recorder.complete(
            NetworkTaskKey(owner: self, taskIdentifier: 4),
            request: makeSnapshot(),
            response: .init(statusCode: 404, headers: [:]),
            responseData: nil,
            error: nil,
            metrics: nil
        )
        await recorder.complete(
            NetworkTaskKey(owner: self, taskIdentifier: 5),
            request: makeSnapshot(),
            response: .init(statusCode: 503, headers: [:]),
            responseData: nil,
            error: nil,
            metrics: nil
        )
        await recorder.complete(
            NetworkTaskKey(owner: self, taskIdentifier: 6),
            request: makeSnapshot(),
            response: nil,
            responseData: nil,
            error: URLError(.notConnectedToInternet),
            metrics: nil
        )
        await logger.flush()

        let events = await destination.snapshot()
        XCTAssertEqual(events.map(\.level), [.warning, .error, .error])
        XCTAssertEqual(events.last?.error?.domain, NSURLErrorDomain)
        XCTAssertEqual(events.last?.error?.code, URLError.notConnectedToInternet.rawValue)
    }

    func testDisabledRecorderCapturesNothing() async {
        let store = NetworkLogStore()
        let recorder = NetworkLogRecorder(store: store, isEnabled: false)

        await recorder.complete(
            NetworkTaskKey(owner: self, taskIdentifier: 7),
            request: makeSnapshot(),
            response: .init(statusCode: 200, headers: [:]),
            responseData: nil,
            error: nil,
            metrics: nil
        )

        let records = await store.all()
        XCTAssertTrue(records.isEmpty)
    }

    func testStoreEvictsOldestBeyondItsLimit() async {
        let store = NetworkLogStore(limit: 2)
        let recorder = NetworkLogRecorder(store: store)

        for index in 0..<4 {
            await recorder.complete(
                NetworkTaskKey(owner: self, taskIdentifier: 100 + index),
                request: makeSnapshot(url: "https://api.example.com/v1/item/\(index)"),
                response: .init(statusCode: 200, headers: [:]),
                responseData: nil,
                error: nil,
                metrics: nil
            )
        }

        let records = await store.all()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.request.path), ["/v1/item/3", "/v1/item/2"])
    }
}
