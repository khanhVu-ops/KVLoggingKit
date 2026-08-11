import Foundation
import KVLoggingKit

/// Captured payload for one side of an exchange.
///
/// Bodies are never copied into `LogEvent` metadata. They stay in
/// `NetworkLogStore` so the on-device viewer can show them while remote
/// destinations only ever receive the redacted summary line.
public enum NetworkLogBodyContent: Codable, Equatable, Sendable {
    case empty
    case text(String)
    case binary
    case notCaptured(reason: String)
}

public struct NetworkLogBody: Codable, Equatable, Sendable {
    public var content: NetworkLogBodyContent
    public var byteCount: Int
    public var isTruncated: Bool
    public var contentType: String?

    public init(
        content: NetworkLogBodyContent,
        byteCount: Int = 0,
        isTruncated: Bool = false,
        contentType: String? = nil
    ) {
        self.content = content
        self.byteCount = byteCount
        self.isTruncated = isTruncated
        self.contentType = contentType
    }

    public static let empty = NetworkLogBody(content: .empty)

    public var text: String? {
        guard case let .text(value) = content else { return nil }
        return value
    }
}

public struct NetworkLogRequest: Codable, Equatable, Sendable {
    public var method: String
    public var url: String
    public var host: String?
    public var path: String?
    public var headers: [String: String]
    public var body: NetworkLogBody
    public var timeout: TimeInterval

    public init(
        method: String,
        url: String,
        host: String?,
        path: String?,
        headers: [String: String],
        body: NetworkLogBody,
        timeout: TimeInterval
    ) {
        self.method = method
        self.url = url
        self.host = host
        self.path = path
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct NetworkLogResponse: Codable, Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: NetworkLogBody

    public init(
        statusCode: Int,
        headers: [String: String],
        body: NetworkLogBody
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct NetworkLogMetrics: Codable, Equatable, Sendable {
    public var domainLookup: TimeInterval?
    public var connect: TimeInterval?
    public var secureConnect: TimeInterval?
    public var timeToFirstByte: TimeInterval?
    public var requestBytesSent: Int64
    public var responseBytesReceived: Int64
    public var networkProtocolName: String?
    public var isReusedConnection: Bool
    public var isProxyConnection: Bool
    public var isCellular: Bool

    public init(
        domainLookup: TimeInterval? = nil,
        connect: TimeInterval? = nil,
        secureConnect: TimeInterval? = nil,
        timeToFirstByte: TimeInterval? = nil,
        requestBytesSent: Int64 = 0,
        responseBytesReceived: Int64 = 0,
        networkProtocolName: String? = nil,
        isReusedConnection: Bool = false,
        isProxyConnection: Bool = false,
        isCellular: Bool = false
    ) {
        self.domainLookup = domainLookup
        self.connect = connect
        self.secureConnect = secureConnect
        self.timeToFirstByte = timeToFirstByte
        self.requestBytesSent = requestBytesSent
        self.responseBytesReceived = responseBytesReceived
        self.networkProtocolName = networkProtocolName
        self.isReusedConnection = isReusedConnection
        self.isProxyConnection = isProxyConnection
        self.isCellular = isCellular
    }
}

public struct NetworkLogRecord: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case pending
        case succeeded
        case failed
    }

    public let id: UUID
    public var startedAt: Date
    public var state: State
    public var request: NetworkLogRequest
    public var response: NetworkLogResponse?
    public var metrics: NetworkLogMetrics?
    public var error: LogError?
    public var duration: TimeInterval?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        state: State = .pending,
        request: NetworkLogRequest,
        response: NetworkLogResponse? = nil,
        metrics: NetworkLogMetrics? = nil,
        error: LogError? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.state = state
        self.request = request
        self.response = response
        self.metrics = metrics
        self.error = error
        self.duration = duration
    }

    public var statusCode: Int? {
        response?.statusCode
    }

    public var isSuccess: Bool {
        guard let statusCode else { return false }
        return (200..<400).contains(statusCode)
    }

    /// Short line used for list rows and for the emitted `LogEvent` message.
    public var summary: String {
        let target = [host, path].compactMap { $0 }.joined()
        let location = target.isEmpty ? request.url : target

        switch state {
        case .pending:
            return "\(request.method) \(location) → …"
        case .failed where statusCode == nil:
            return "\(request.method) \(location) → error"
        case .succeeded, .failed:
            return "\(request.method) \(location) → \(statusCode.map(String.init) ?? "error")"
        }
    }

    private var host: String? { request.host }
    private var path: String? { request.path }
}
