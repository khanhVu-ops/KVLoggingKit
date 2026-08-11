import Foundation

/// Answers the sample requests with canned JSON so the Network tab has content
/// without the example depending on an internet connection.
///
/// It sits *underneath* `NetworkLoggingURLProtocol`: capture replays the
/// request into a session configured with this protocol, so the whole
/// interception path runs exactly as it would against a real server.
public final class ExampleAPIStub: URLProtocol, @unchecked Sendable {
    public static func replayConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExampleAPIStub.self]
        return configuration
    }

    public override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.example.com"
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        let path = request.url?.path ?? ""
        let (statusCode, body): (Int, String)

        switch path {
        case "/v1/login":
            (statusCode, body) = (200, #"{"user":{"id":42,"name":"Khanh"},"access_token":"super-secret-token"}"#)
        case "/v1/profile":
            (statusCode, body) = (200, #"{"id":42,"email":"reader@example.com","plan":"pro","credits":120}"#)
        case "/v1/missing":
            (statusCode, body) = (404, #"{"error":"not_found","message":"No such resource"}"#)
        default:
            (statusCode, body) = (500, #"{"error":"server_error"}"#)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Set-Cookie": "session=abc123; HttpOnly"
            ]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    public override func stopLoading() {}
}
