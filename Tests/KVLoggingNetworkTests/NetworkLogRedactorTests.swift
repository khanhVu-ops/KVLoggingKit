import XCTest
@testable import KVLoggingNetwork

final class NetworkLogRedactorTests: XCTestCase {
    func testRedactsSensitiveHeadersCaseInsensitively() {
        let redactor = NetworkLogRedactor.default

        let headers = redactor.redacted(headers: [
            "Authorization": "Bearer secret-token",
            "AUTHORIZATION": "Bearer other",
            "Accept": "application/json"
        ])

        XCTAssertEqual(headers["Authorization"], "<redacted>")
        XCTAssertEqual(headers["AUTHORIZATION"], "<redacted>")
        XCTAssertEqual(headers["Accept"], "application/json")
    }

    func testRedactsSensitiveQueryItemsAndKeepsOthers() {
        let redactor = NetworkLogRedactor.default
        let url = URL(string: "https://api.example.com/v1/users?page=2&access_token=abc123")!

        let redacted = redactor.redactedURLString(url)

        XCTAssertTrue(redacted.contains("page=2"))
        XCTAssertFalse(redacted.contains("abc123"))
        // Plain text, not `%3Credacted%3E` — a percent-encoded placeholder is
        // unreadable in the row that shows the URL.
        XCTAssertTrue(redacted.contains("access_token=REDACTED"))
    }

    func testRedactsNestedJSONBodyKeys() throws {
        let redactor = NetworkLogRedactor.default
        let json = #"{"user":{"email":"a@b.com","password":"hunter2"},"items":[{"token":"t1"}]}"#

        let body = redactor.requestBody(
            from: Data(json.utf8),
            contentType: "application/json"
        )

        let text = try XCTUnwrap(body.text)
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("t1"))
        XCTAssertTrue(text.contains("a@b.com"))
        XCTAssertTrue(text.contains("<redacted>"))
    }

    func testTruncatesBodiesBeyondTheLimit() {
        let redactor = NetworkLogRedactor(maximumBodyByteCount: 16)
        let payload = String(repeating: "a", count: 100)

        let body = redactor.responseBody(from: Data(payload.utf8), contentType: "text/plain")

        XCTAssertTrue(body.isTruncated)
        XCTAssertEqual(body.byteCount, 100)
        XCTAssertEqual(body.text?.count, 16)
    }

    func testReportsUncapturedStreamBodies() {
        let body = NetworkLogRedactor.default.requestBody(
            from: nil,
            contentType: nil,
            hasUncapturableStream: true
        )

        guard case let .notCaptured(reason) = body.content else {
            return XCTFail("Expected a notCaptured body, got \(body.content)")
        }
        XCTAssertTrue(reason.contains("httpBodyStream"))
    }

    func testBodyCaptureCanBeTurnedOff() {
        let redactor = NetworkLogRedactor.headersAndBodiesOff

        let request = redactor.requestBody(from: Data("hello".utf8), contentType: "text/plain")
        let response = redactor.responseBody(from: Data("hello".utf8), contentType: "text/plain")

        guard case .notCaptured = request.content, case .notCaptured = response.content else {
            return XCTFail("Expected both bodies to be withheld")
        }
    }

    func testDetectsBinaryPayloads() {
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02])

        let body = NetworkLogRedactor.default.responseBody(from: data, contentType: "image/png")

        XCTAssertEqual(body.content, .binary)
        XCTAssertEqual(body.byteCount, 7)
    }
}
