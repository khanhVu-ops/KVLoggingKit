import KVLoggingConsole
import KVLoggingKit
import KVLoggingLocal
import XCTest

/// Compile-time guard for the "Minimal setup" snippet in the README.
///
/// The body is never run — installing the console would swizzle
/// `URLSessionConfiguration` for the whole test process and leak into the
/// network tests. Compiling it is the point: if the setup API changes shape,
/// the documented snippet stops building here instead of in a user's project.
private func documentedMinimalSetup() -> LogClient {
    var destinations: [any LogDestination] = [SystemLogDestination()]
    if let console = LogConsole.install(
        policy: .debugOrBundleIdentifiers(["varmeta.test.app"])
    ) {
        destinations.append(console)
    }

    let client = LogClient(
        configuration: .init(minimumLevel: .debug),
        destinations: destinations
    )

    LogConsole.startNetworkCapture(logger: client)

    return client
}

private func documentedScopedCapture(client: LogClient) {
    LogConsole.startNetworkCapture(
        logger: client,
        scope: .allSessions,
        excluding: { $0.url?.host != "logs.example.com" }
    )
}

final class DocumentedSetupTests: XCTestCase {
    /// A denying policy touches no global state, so this is safe to execute.
    func testInstallReturnsNilWhenThePolicyDenies() {
        XCTAssertNil(LogConsole.install(policy: .disabled))
    }

    func testStartNetworkCaptureIsSafeBeforeInstall() {
        // Only meaningful when the console was never installed in this process.
        guard !LogConsole.isInstalled else { return }
        XCTAssertNil(LogConsole.startNetworkCapture(logger: nil, scope: .manual))
    }

    func testSnippetsAreReferencedSoTheyCompile() {
        XCTAssertNotNil(documentedMinimalSetup as Any)
        XCTAssertNotNil(documentedScopedCapture as Any)
    }
}
