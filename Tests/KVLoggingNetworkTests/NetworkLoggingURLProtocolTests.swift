import Foundation
import XCTest
@testable import KVLoggingNetwork

/// Serves canned responses so the interception path can be exercised without
/// touching the network. It sits underneath `NetworkLoggingURLProtocol` in the
/// replay session.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
    }

    nonisolated(unsafe) static var stub = Stub(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(#"{"ok":true}"#.utf8)
    )

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.stub
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class NetworkLoggingURLProtocolTests: XCTestCase {
    override func tearDown() {
        NetworkLoggingURLProtocol.settings = .init()
        super.tearDown()
    }

    // MARK: - Installation

    func testInstallAddsTheProtocolExactlyOnce() {
        let configuration = URLSessionConfiguration.ephemeral

        NetworkLoggingURLProtocol.install(in: configuration)
        NetworkLoggingURLProtocol.install(in: configuration)

        let matches = (configuration.protocolClasses ?? []).filter {
            $0 === NetworkLoggingURLProtocol.self
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(configuration.protocolClasses?.first === NetworkLoggingURLProtocol.self)
    }

    func testCanInitSkipsNonHTTPSchemes() {
        let fileRequest = URLRequest(url: URL(string: "file:///tmp/a.json")!)
        let httpRequest = URLRequest(url: URL(string: "https://api.example.com/v1")!)

        XCTAssertFalse(NetworkLoggingURLProtocol.canInit(with: fileRequest))
        XCTAssertTrue(NetworkLoggingURLProtocol.canInit(with: httpRequest))
    }

    func testShouldCaptureCanExcludeTheLogUploadEndpoint() {
        NetworkLoggingURLProtocol.settings = .init(
            shouldCapture: { $0.url?.host != "logs.example.com" }
        )

        let excluded = URLRequest(url: URL(string: "https://logs.example.com/v1/events")!)
        let included = URLRequest(url: URL(string: "https://api.example.com/v1/users")!)

        XCTAssertFalse(NetworkLoggingURLProtocol.canInit(with: excluded))
        XCTAssertTrue(NetworkLoggingURLProtocol.canInit(with: included))
    }

    // MARK: - End to end

    func testCapturesRequestAndResponseBodiesEndToEnd() async throws {
        let store = NetworkLogStore()
        StubURLProtocol.stub = .init(
            statusCode: 201,
            headers: ["Content-Type": "application/json", "Set-Cookie": "session=abc"],
            body: Data(#"{"id":7,"token":"leak-me"}"#.utf8)
        )
        NetworkLoggingURLProtocol.settings = .init(
            recorder: NetworkLogRecorder(store: store),
            replayConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [StubURLProtocol.self]
                return configuration
            }
        )

        let configuration = URLSessionConfiguration.ephemeral
        NetworkLoggingURLProtocol.install(in: configuration)
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: URL(string: "https://api.example.com/v1/login?api_key=k1")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer top-secret", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"user":"kv","password":"hunter2"}"#.utf8)

        let (data, response) = try await session.data(for: request)

        // The caller still sees the untouched response.
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"id":7,"token":"leak-me"}"#)

        let captured = await waitForRecord(in: store)
        let record = try XCTUnwrap(captured)

        XCTAssertEqual(record.state, .succeeded)
        XCTAssertEqual(record.statusCode, 201)
        XCTAssertEqual(record.request.method, "POST")

        // Credentials are redacted everywhere they can appear.
        XCTAssertEqual(record.request.headers["Authorization"], "<redacted>")
        XCTAssertEqual(record.response?.headers["Set-Cookie"], "<redacted>")
        XCTAssertFalse(record.request.url.contains("k1"))
        XCTAssertFalse(try XCTUnwrap(record.request.body.text).contains("hunter2"))
        XCTAssertFalse(try XCTUnwrap(record.response?.body.text).contains("leak-me"))

        // Non-sensitive payload survives so the exchange is still debuggable.
        XCTAssertTrue(try XCTUnwrap(record.request.body.text).contains("\"kv\""))
        XCTAssertTrue(try XCTUnwrap(record.response?.body.text).contains("\"id\""))

        XCTAssertTrue(record.curlCommand.contains("curl -X POST"))
    }

    func testCapturesBodiesSuppliedAsAStream() async throws {
        let store = NetworkLogStore()
        StubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data())
        NetworkLoggingURLProtocol.settings = .init(
            recorder: NetworkLogRecorder(store: store),
            replayConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [StubURLProtocol.self]
                return configuration
            }
        )

        let configuration = URLSessionConfiguration.ephemeral
        NetworkLoggingURLProtocol.install(in: configuration)
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: URL(string: "https://api.example.com/v1/upload")!)
        request.httpMethod = "PUT"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBodyStream = InputStream(data: Data("streamed payload".utf8))

        _ = try await session.data(for: request)

        let captured = await waitForRecord(in: store)
        let record = try XCTUnwrap(captured)
        XCTAssertEqual(record.request.body.text, "streamed payload")
    }

    /// The recorder finishes on a detached task, so the record can land a beat
    /// after `data(for:)` returns.
    private func waitForRecord(in store: NetworkLogStore) async -> NetworkLogRecord? {
        for _ in 0..<100 {
            if let record = await store.all().first, record.state != .pending {
                return record
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await store.all().first
    }
}
