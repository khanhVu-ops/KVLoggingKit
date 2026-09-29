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
    /// What the far side of the replay received, i.e. what the server would.
    nonisolated(unsafe) static var receivedBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.receivedBodies.append(request.httpBody ?? Self.readAll(request.httpBodyStream))

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

    private static func readAll(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
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

    /// `LogConsole.install()`'s default scope reaches every session in the
    /// process, SDKs' included, so a body the interception mangles is mangled
    /// app-wide. Before 1.2.0 every request body arrived empty here.
    func testUploadsThroughACustomConfigurationArriveIntact() async throws {
        InstallStubProtocol.receivedBodies = []
        let session = URLSession(configuration: .default)
        let payload = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 10) })

        var streamed = URLRequest(url: URL(string: "https://api.example.com/v1/photos")!)
        streamed.httpMethod = "POST"
        streamed.httpBodyStream = InputStream(data: payload)
        _ = try await session.data(for: streamed)

        var plain = URLRequest(url: URL(string: "https://api.example.com/v1/photos")!)
        plain.httpMethod = "POST"
        plain.httpBody = payload
        _ = try await session.data(for: plain)

        var upload = URLRequest(url: URL(string: "https://api.example.com/v1/photos")!)
        upload.httpMethod = "POST"
        _ = try await session.upload(for: upload, from: payload)

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvlogging-upload-\(UUID().uuidString).bin")
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await session.upload(for: upload, fromFile: file)

        XCTAssertEqual(
            InstallStubProtocol.receivedBodies.map(\.count),
            Array(repeating: payload.count, count: 4)
        )
        for (index, body) in InstallStubProtocol.receivedBodies.enumerated() {
            XCTAssertTrue(body == payload, "request \(index) arrived altered")
        }
    }
}
