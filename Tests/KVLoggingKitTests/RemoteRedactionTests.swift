import XCTest
@testable import KVLoggingKit

private struct TokenError: Error, CustomStringConvertible {
    var description: String { "refresh failed for person@example.com" }
}

final class RemoteRedactionTests: XCTestCase {
    func testPrivateMetadataBecomesRedacted() {
        let event = LogEvent(
            level: .info,
            message: "profile loaded",
            metadata: [
                "user_id": .public("123"),
                "email": .private("person@example.com")
            ]
        )

        let redacted = event.redactedForRemote()

        XCTAssertEqual(redacted.metadata["user_id"]?.value, .string("123"))
        XCTAssertEqual(redacted.metadata["email"]?.value, .string("<redacted>"))
    }

    /// The gap that made declaring a field private meaningless: callers
    /// interpolate the same value into the message text.
    func testMessageTextIsScrubbedNotJustMetadata() {
        let event = LogEvent(
            level: .warning,
            message: "retry for person@example.com with Bearer abc.def.ghijkl"
        )

        let redacted = event.redactedForRemote()

        XCTAssertFalse(redacted.message.contains("person@example.com"))
        XCTAssertFalse(redacted.message.contains("abc.def.ghijkl"))
    }

    func testErrorDescriptionIsScrubbed() {
        let event = LogEvent(level: .error, message: "failed", error: TokenError())

        let redacted = event.redactedForRemote()

        XCTAssertFalse(redacted.error?.message.contains("person@example.com") == true)
        XCTAssertTrue(redacted.error?.message.contains("<redacted-email>") == true)
    }

    func testScrubbingCanBeTurnedOff() {
        let event = LogEvent(level: .info, message: "person@example.com")

        let redacted = event.redactedForRemote(scrubbing: .none)

        XCTAssertEqual(redacted.message, "person@example.com")
    }

    func testBridgedErrorsKeepDomainAndCode() {
        let event = LogEvent(
            level: .error,
            message: "offline",
            error: URLError(.notConnectedToInternet)
        )

        XCTAssertEqual(event.error?.domain, NSURLErrorDomain)
        XCTAssertEqual(event.error?.code, URLError.notConnectedToInternet.rawValue)
        XCTAssertEqual(event.error?.type, NSURLErrorDomain)
    }
}
