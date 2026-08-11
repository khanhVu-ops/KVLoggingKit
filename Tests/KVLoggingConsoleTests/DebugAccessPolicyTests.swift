import XCTest
@testable import KVLoggingConsole

final class DebugAccessPolicyTests: XCTestCase {
    func testBundleIdentifierAllowlistMatchesExactly() {
        let policy = DebugAccessPolicy(
            rules: [.bundleIdentifiers(["varmeta.test.app"])]
        )

        XCTAssertTrue(policy.isAllowed(bundleIdentifier: "varmeta.test.app", environment: [:]))
        XCTAssertFalse(policy.isAllowed(bundleIdentifier: "varmeta.prod.app", environment: [:]))
        XCTAssertFalse(policy.isAllowed(bundleIdentifier: nil, environment: [:]))
    }

    func testRulesAreCombinedWithOr() {
        let policy = DebugAccessPolicy(
            rules: [.bundleIdentifiers(["varmeta.test.app"]), .environmentVariable("KV_CONSOLE")]
        )

        XCTAssertTrue(
            policy.isAllowed(bundleIdentifier: "other.app", environment: ["KV_CONSOLE": "1"])
        )
        XCTAssertTrue(
            policy.isAllowed(bundleIdentifier: "varmeta.test.app", environment: [:])
        )
    }

    func testEnvironmentVariableSetToZeroDoesNotOpenTheConsole() {
        let policy = DebugAccessPolicy(rules: [.environmentVariable("KV_CONSOLE")])

        XCTAssertFalse(
            policy.isAllowed(bundleIdentifier: "any.app", environment: ["KV_CONSOLE": "0"])
        )
    }

    func testDisabledPolicyNeverAllows() {
        XCTAssertFalse(
            DebugAccessPolicy.disabled.isAllowed(bundleIdentifier: "any.app", environment: [:])
        )
    }

    /// The production case: a release build whose identifier is not allowlisted
    /// must not be able to open the console.
    func testReleaseBuildWithUnlistedIdentifierIsDenied() {
        let policy = DebugAccessPolicy.debugOrBundleIdentifiers(["varmeta.test.app"])
        let allowed = policy.isAllowed(bundleIdentifier: "varmeta.prod.app", environment: [:])

        #if DEBUG
        XCTAssertTrue(allowed, "debug builds always pass the debugBuild rule")
        #else
        XCTAssertFalse(allowed)
        #endif
    }
}
