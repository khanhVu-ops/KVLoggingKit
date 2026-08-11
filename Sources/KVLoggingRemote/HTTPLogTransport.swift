import Foundation
import KVLoggingKit

public enum HTTPLogTransportError: Error, Equatable {
    case invalidResponse
    case unacceptableStatusCode(Int)
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
