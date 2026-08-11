import Foundation
import XCTest
import KVLoggingKit
@testable import KVLoggingRemote

final class HTTPLogTransportTests: XCTestCase {
    final class RequestStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storedRequest: URLRequest?
        private var storedBody: Data?
        private var storedStatusCode = 200

        func configure(statusCode: Int) {
            lock.withLock {
                storedStatusCode = statusCode
                storedRequest = nil
                storedBody = nil
            }
        }

        func record(_ request: URLRequest) -> Int {
            lock.withLock {
                storedRequest = request
                storedBody = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
                return storedStatusCode
            }
        }

        func request() -> URLRequest? {
            lock.withLock { storedRequest }
        }

        func body() -> Data? {
            lock.withLock { storedBody }
        }

        private static func readBodyStream(_ stream: InputStream?) -> Data? {
            guard let stream else { return nil }
            stream.open()
            defer { stream.close() }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    final class URLProtocolStub: URLProtocol, @unchecked Sendable {
        static let store = RequestStore()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let statusCode = Self.store.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testSendsJSONPayloadAndHeaders() async throws {
        URLProtocolStub.store.configure(statusCode: 202)
        let transport = HTTPLogTransport(
            endpoint: URL(string: "https://logs.example.com/events")!,
            headers: ["Authorization": "test-key"],
            session: makeSession()
        )

        try await transport.send([LogEvent(level: .info, message: "remote event")])

        let request = try XCTUnwrap(URLProtocolStub.store.request())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "test-key")
        let body = try XCTUnwrap(URLProtocolStub.store.body())
        XCTAssertTrue(String(data: body, encoding: .utf8)?.contains("remote event") == true)
    }

    func testRejectsNonSuccessStatusCode() async {
        URLProtocolStub.store.configure(statusCode: 503)
        let transport = HTTPLogTransport(
            endpoint: URL(string: "https://logs.example.com/events")!,
            session: makeSession()
        )

        do {
            try await transport.send([LogEvent(level: .error, message: "failure")])
            XCTFail("Expected status-code error")
        } catch {
            XCTAssertEqual(error as? HTTPLogTransportError, .unacceptableStatusCode(503))
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}
