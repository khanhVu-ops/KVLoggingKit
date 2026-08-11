import XCTest
@testable import KVLoggingKit

final class LogEventTests: XCTestCase {
    private struct SampleError: Error, CustomStringConvertible {
        let description = "sample failure"
    }

    func testLevelsSortFromLeastToMostSevere() {
        XCTAssertEqual(
            LogLevel.allCases.sorted(),
            [.trace, .debug, .info, .notice, .warning, .error, .critical]
        )
    }

    func testFieldsPreserveTypedValuesAndPrivacy() {
        let fields: LogMetadata = [
            "name": .public("Taylor"),
            "attempt": .public(3),
            "ratio": .public(0.5),
            "enabled": .private(true)
        ]

        XCTAssertEqual(fields["name"]?.value, .string("Taylor"))
        XCTAssertEqual(fields["attempt"]?.value, .integer(3))
        XCTAssertEqual(fields["ratio"]?.value, .double(0.5))
        XCTAssertEqual(fields["enabled"]?.privacy, .private)
    }

    func testEventCapturesErrorAndSourceLocation() {
        let event = LogEvent(
            level: .error,
            message: "Operation failed",
            error: SampleError(),
            source: .init(file: "Feature.swift", function: "run()", line: 42)
        )

        XCTAssertEqual(event.error?.message, "sample failure")
        XCTAssertTrue(event.error?.type.contains("SampleError") == true)
        XCTAssertEqual(event.source.file, "Feature.swift")
        XCTAssertEqual(event.source.line, 42)
    }

    func testRemoteSanitizationRedactsPrivateFields() {
        let event = LogEvent(
            level: .info,
            message: "Loaded profile",
            metadata: [
                "user_id": .public("123"),
                "email": .private("person@example.com")
            ]
        )

        let sanitized = event.redactedForRemote()

        XCTAssertEqual(sanitized.metadata["user_id"]?.value, .string("123"))
        XCTAssertEqual(sanitized.metadata["email"]?.value, .string("<redacted>"))
    }
}
