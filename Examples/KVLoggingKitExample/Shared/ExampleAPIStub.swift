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
        if path == "/v1/chat/interact" {
            streamChatReply()
            return
        }

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

    public override func stopLoading() {
        isStopped = true
    }

    private var isStopped = false

    /// A chat answer as the AI Chat backend streams it: typed JSON events, the
    /// answer split into `chunk`s, a tool `activity`, and a closing `done`.
    private func streamChatReply() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-cache"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let answer = ["Giá vàng", " hôm nay", " dao động", " quanh 140", " triệu đồng", " mỗi lượng.", "\\n\\nNguồn:", " SJC."]
        var events: [String] = [
            #"{"type":"start","session_id":"s-42","user_message_id":"m-1","credits_charged":1,"total_tokens":345}"#,
            #"{"type":"activity","status":"started","activity":"web_search","content":"Searching in web…"}"#,
            #"{"type":"activity","status":"completed","activity":"web_search","content":"Complete web action."}"#
        ]
        events += answer.map { #"{"type":"chunk","content":"\#($0)"}"# }
        events.append(#"{"type":"audio_chunk","content":"\#(String(repeating: "SUQzBAAAAAAA", count: 400))"}"#)
        events.append(#"{"type":"done","message_id":"m-2"}"#)

        let queue = DispatchQueue(label: "ExampleAPIStub.sse")
        for (index, event) in events.enumerated() {
            queue.asyncAfter(deadline: .now() + 0.35 * Double(index + 1)) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.client?.urlProtocol(self, didLoad: Data("data: \(event)\n\n".utf8))
                if index == events.count - 1 {
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
        }
    }
}
