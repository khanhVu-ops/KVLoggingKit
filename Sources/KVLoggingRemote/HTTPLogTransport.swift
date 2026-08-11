import Foundation
import KVLoggingKit

public enum HTTPLogTransportError: Error, Equatable, RetryableError {
    case invalidResponse
    case unacceptableStatusCode(Int)

    public var isRetryable: Bool {
        switch self {
        case .invalidResponse:
            return true
        case let .unacceptableStatusCode(code):
            // 4xx means the request itself is wrong — a bad key, a payload the
            // server refuses — and will fail the same way next time. 408 and
            // 429 are the exceptions that do clear on their own.
            guard (400..<500).contains(code) else { return true }
            return code == 408 || code == 429
        }
    }
}

public struct HTTPLogTransport: LogTransport, @unchecked Sendable {
    private struct Payload: Encodable {
        let events: [LogEvent]
    }

    private let endpoint: URL
    private let headers: [String: String]
    private let session: URLSession

    public init(
        endpoint: URL,
        headers: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.session = session
    }

    public func send(_ events: [LogEvent]) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Payload(events: events))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (_, response) = try await data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPLogTransportError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HTTPLogTransportError.unacceptableStatusCode(httpResponse.statusCode)
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: HTTPLogTransportError.invalidResponse)
                }
            }.resume()
        }
    }
}
