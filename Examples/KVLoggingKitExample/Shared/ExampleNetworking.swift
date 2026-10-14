import Foundation
import KVLoggingConsole
import KVLoggingKit
import KVLoggingNetwork

/// Sample API calls that exercise the capture path end to end.
public struct ExampleNetworking: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        NetworkLoggingURLProtocol.install(in: configuration)
        session = URLSession(configuration: configuration)
    }

    /// Wires capture to the console's store and to the log pipeline.
    ///
    /// A real app stops at `startNetworkCapture`. The extra step here points
    /// the replay session at the local stub so the example needs no network.
    public static func installCapture(logger: LogClient) {
        guard LogConsole.startNetworkCapture(logger: logger, scope: .manual) != nil else {
            return
        }

        var settings = NetworkLoggingURLProtocol.settings
        settings.replayConfiguration = { ExampleAPIStub.replayConfiguration() }
        NetworkLoggingURLProtocol.settings = settings
    }

    public func performSampleCalls() async {
        await post(
            "https://api.example.com/v1/login?api_key=live-key-123",
            body: #"{"username":"khanh","password":"hunter2"}"#
        )
        await get("https://api.example.com/v1/profile")
        await get("https://api.example.com/v1/missing")
    }

    /// Reads a server-sent events reply line by line, the way a chat client does.
    @available(iOS 15.0, macOS 12.0, *)
    public func streamSampleChat() async {
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/chat/interact")!)
        request.httpMethod = "POST"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"message":"Giá vàng hôm nay?","web_search":true}"#.utf8)

        guard let (bytes, _) = try? await session.bytes(for: request) else { return }
        do {
            for try await _ in bytes.lines {}
        } catch {}
    }

    private func get(_ urlString: String) async {
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue("Bearer live-access-token", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    private func post(_ urlString: String, body: String) async {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer live-access-token", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(body.utf8)
        _ = try? await session.data(for: request)
    }
}
