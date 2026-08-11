import XCTest
@testable import KVLoggingNetwork

final class CURLCommandTests: XCTestCase {
    func testBuildsCommandWithHeadersAndBody() {
        let record = NetworkLogRecord(
            request: .init(
                method: "POST",
                url: "https://api.example.com/v1/login",
                host: "api.example.com",
                path: "/v1/login",
                headers: ["Content-Type": "application/json", "Authorization": "<redacted>"],
                body: .init(content: .text(#"{"user":"kv"}"#), byteCount: 13),
                timeout: 60
            )
        )

        let command = record.curlCommand

        XCTAssertTrue(command.hasPrefix("curl -X POST 'https://api.example.com/v1/login'"))
        XCTAssertTrue(command.contains("-H 'Content-Type: application/json'"))
        XCTAssertTrue(command.contains("-H 'Authorization: <redacted>'"))
        XCTAssertTrue(command.contains(#"--data-binary '{"user":"kv"}'"#))
    }

    func testEscapesSingleQuotesSoTheCommandStaysValid() {
        let record = NetworkLogRecord(
            request: .init(
                method: "POST",
                url: "https://api.example.com/search",
                host: "api.example.com",
                path: "/search",
                headers: [:],
                body: .init(content: .text("it's here"), byteCount: 9),
                timeout: 60
            )
        )

        XCTAssertTrue(record.curlCommand.contains(#"--data-binary 'it'\''s here'"#))
    }

    func testAnnotatesBodiesThatWereNotCaptured() {
        let record = NetworkLogRecord(
            request: .init(
                method: "PUT",
                url: "https://api.example.com/upload",
                host: "api.example.com",
                path: "/upload",
                headers: [:],
                body: .init(content: .notCaptured(reason: "Body was supplied as an httpBodyStream")),
                timeout: 60
            )
        )

        XCTAssertTrue(record.curlCommand.contains("# body not captured: Body was supplied as an httpBodyStream"))
    }
}
