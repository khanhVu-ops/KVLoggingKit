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

    func testStrictProcessorRedactsSensitiveMessagePatterns() async {
        let processor = PrivacyProcessor.strict(allowedMetadataKeys: [])
        let event = LogEvent(
            level: .warning,
            message: "Bearer abc.def.ghi email person@example.com phone +84 912 345 678"
        )

        let result = await processor.process(event)

        XCTAssertFalse(result?.message.contains("abc.def.ghi") == true)
        XCTAssertFalse(result?.message.contains("person@example.com") == true)
        XCTAssertFalse(result?.message.contains("912 345 678") == true)
        XCTAssertTrue(result?.message.contains("<redacted") == true)
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
}
