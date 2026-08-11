import XCTest
@testable import KVLoggingKit

final class PrivacyProcessorTests: XCTestCase {
    func testStrictProcessorDropsMetadataOutsideAllowlist() async {
        let processor = PrivacyProcessor.strict(
            allowedMetadataKeys: ["user_id", "email"]
        )
        let event = LogEvent(
            level: .info,
            message: "profile",
            metadata: [
                "user_id": .public("123"),
                "email": .private("person@example.com"),
                "access_token": .private("secret")
            ]
        )

        let result = await processor.process(event)

        XCTAssertEqual(Set(result?.metadata.keys.map { $0 } ?? []), ["user_id", "email"])
        XCTAssertEqual(result?.metadata["email"]?.value, .string("person@example.com"))
    }

    func testStrictProcessorRedactsCredentialsAndEmails() async {
        let processor = PrivacyProcessor.strict(allowedMetadataKeys: [])
        let event = LogEvent(
            level: .warning,
            message: "Bearer abc.def.ghi email person@example.com access_token=zzz999"
        )

        let result = await processor.process(event)

        XCTAssertFalse(result?.message.contains("abc.def.ghi") == true)
        XCTAssertFalse(result?.message.contains("person@example.com") == true)
        XCTAssertFalse(result?.message.contains("zzz999") == true)
        XCTAssertTrue(result?.message.contains("<redacted") == true)
    }

    /// Phone matching is opt-in because a run of digits is indistinguishable
    /// from a duration, an identifier, or a timestamp.
    func testDefaultRedactionLeavesNumbersAlone() async {
        let processor = PrivacyProcessor.standard
        let event = LogEvent(
            level: .info,
            message: "Request finished in 1234.5678 ms order=8801234567 at 2026-08-11 17:15:23.123"
        )

        let result = await processor.process(event)

        XCTAssertEqual(result?.message, event.message)
    }

    func testPhoneNumbersAreRedactedWhenOptedIn() async {
        let processor = PrivacyProcessor(redaction: .includingPhoneNumbers)
        let event = LogEvent(
            level: .info,
            message: "called +84 912 345 678 after 1234.5678 ms"
        )

        let result = await processor.process(event)

        XCTAssertFalse(result?.message.contains("912 345 678") == true)
        XCTAssertTrue(result?.message.contains("<redacted-phone>") == true)
        XCTAssertTrue(result?.message.contains("1234.5678 ms") == true)
    }

    func testStrictAllowlistKeepsDeviceContextKeys() async {
        let processor = PrivacyProcessor.strict(allowedMetadataKeys: ["screen"])
        let event = LogEvent(
            level: .info,
            message: "opened",
            metadata: [
                "screen": .public("profile"),
                "app_version": .public("2.1"),
                "session_id": .public("abc"),
                "unexpected": .public("dropped")
            ]
        )

        let result = await processor.process(event)

        XCTAssertEqual(
            Set(result?.metadata.keys.map { $0 } ?? []),
            ["screen", "app_version", "session_id"]
        )
    }

    func testStaticContextOnlyFillsMissingMetadata() async {
        let processor = StaticContextProcessor(
            metadata: [
                "app_version": .public("1.0"),
                "environment": .public("production")
            ]
        )
        let event = LogEvent(
            level: .info,
            message: "launch",
            metadata: ["environment": .public("staging")]
        )

        let result = await processor.process(event)

        XCTAssertEqual(result?.metadata["app_version"]?.value, .string("1.0"))
        XCTAssertEqual(result?.metadata["environment"]?.value, .string("staging"))
    }

    func testDeviceContextAddsAppOSAndSessionMetadata() async {
        let processor = DeviceContextProcessor(
            appVersion: "2.1",
            appBuild: "87",
            osVersion: "iOS 18.0",
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        )

        let result = await processor.process(
            LogEvent(level: .info, message: "launch")
        )

        XCTAssertEqual(result?.metadata["app_version"]?.value, .string("2.1"))
        XCTAssertEqual(result?.metadata["app_build"]?.value, .string("87"))
        XCTAssertEqual(result?.metadata["os_version"]?.value, .string("iOS 18.0"))
        XCTAssertEqual(
            result?.metadata["session_id"]?.value,
            .string("00000000-0000-0000-0000-000000000123")
        )
    }
}
