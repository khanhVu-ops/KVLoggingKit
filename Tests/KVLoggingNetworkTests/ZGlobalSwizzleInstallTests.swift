import Foundation
import ObjectiveC
import XCTest
@testable import KVLoggingNetwork

/// Exercises the real `installGlobally(swizzlingSessionConfigurations: true)` —
/// the call that terminated apps on iOS 26.
///
/// Named to sort last: installing is process-global and cannot be undone, so
/// every other test in this bundle should have run first. Nothing here depends on
/// that ordering, but the tests that predate the swizzle should be observed
/// without it.
private final class InstallStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ZGlobalSwizzleInstallTests: XCTestCase {

    private static func answersProtocolQueries(_ candidate: AnyClass) -> Bool {
        ProtocolClassesSwizzleTests.answersProtocolQueries(candidate)
    }

    override func setUp() {
        super.setUp()
        NetworkLoggingURLProtocol.settings = .init(
            replayConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [InstallStubProtocol.self]
                return configuration
            }
        )
        NetworkLoggingURLProtocol.installGlobally(swizzlingSessionConfigurations: true)
    }

    func testEveryEntryOnAFreshConfigurationAnswersCanInitWithRequest() {
        for label in ["default", "ephemeral"] {
            let configuration = label == "default"
                ? URLSessionConfiguration.default
                : URLSessionConfiguration.ephemeral
            let classes = configuration.protocolClasses ?? []

            let deaf = classes.filter {
                !Self.answersProtocolQueries($0)
            }
            XCTAssertEqual(
                deaf.map { NSStringFromClass($0) },
                [],
                "\(label) has entries that would crash CFNetwork"
            )
            XCTAssertEqual(
                classes.filter { $0 === NetworkLoggingURLProtocol.self }.count,
                1,
                "\(label) should carry the protocol exactly once"
            )
        }
    }

    func testRepeatedReadsOfTheSameConfigurationDoNotGrowTheList() {
        let configuration = URLSessionConfiguration.default
        let first = (configuration.protocolClasses ?? []).count

        for round in 2...5 {
            let count = (configuration.protocolClasses ?? []).count
            XCTAssertEqual(count, first, "list grew by round \(round)")
        }
    }

    /// The crash reproduction: a session built from its own configuration, which
    /// `URLProtocol.registerClass` alone does not cover — the reason the swizzle
    /// exists — running a request end to end.
    func testARequestThroughACustomConfigurationCompletes() async throws {
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration)

        let (_, response) = try await session.data(
            from: URL(string: "https://api.example.com/v1/ping")!
        )

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }
}
