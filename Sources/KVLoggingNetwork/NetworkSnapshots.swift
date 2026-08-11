import Foundation

/// Identifies one task across the sessions being observed.
///
/// `taskIdentifier` is only unique inside a single `URLSession`, so the owning
/// session is part of the key.
public struct NetworkTaskKey: Hashable, Sendable {
    private let session: ObjectIdentifier
    private let task: Int

    public init(session: URLSession, taskIdentifier: Int) {
        self.session = ObjectIdentifier(session)
        self.task = taskIdentifier
    }

    public init(owner: AnyObject, taskIdentifier: Int) {
        self.session = ObjectIdentifier(owner)
        self.task = taskIdentifier
    }
}

/// `URLRequest` reduced to `Sendable` values so it can cross into the recorder actor.
public struct URLRequestSnapshot: Sendable {
    public var method: String
    public var url: URL?
    public var headers: [String: String]
    public var body: Data?
    public var hasUncapturableStream: Bool
    public var timeout: TimeInterval

    public init(
        method: String,
        url: URL?,
        headers: [String: String],
        body: Data?,
        hasUncapturableStream: Bool,
        timeout: TimeInterval
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.hasUncapturableStream = hasUncapturableStream
        self.timeout = timeout
    }

    public init(_ request: URLRequest, bodyOverride: Data? = nil) {
        let body = bodyOverride ?? request.httpBody
        self.init(
            method: request.httpMethod ?? "GET",
            url: request.url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body,
            hasUncapturableStream: body == nil && request.httpBodyStream != nil,
            timeout: request.timeoutInterval
        )
    }

    public var contentType: String? {
        headers.first { $0.key.lowercased() == "content-type" }?.value
    }
}

/// `HTTPURLResponse` reduced to `Sendable` values.
public struct HTTPResponseSnapshot: Sendable {
    public var statusCode: Int
    public var headers: [String: String]

    public init(statusCode: Int, headers: [String: String]) {
        self.statusCode = statusCode
        self.headers = headers
    }

    public init?(_ response: URLResponse?) {
        guard let http = response as? HTTPURLResponse else { return nil }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        self.init(statusCode: http.statusCode, headers: headers)
    }

    public var contentType: String? {
        headers.first { $0.key.lowercased() == "content-type" }?.value
    }
}

public extension NetworkLogMetrics {
    /// Reads the last transaction, which is the one that produced the response
    /// after any redirects.
    init?(_ metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return nil }

        func interval(_ start: Date?, _ end: Date?) -> TimeInterval? {
            guard let start, let end else { return nil }
            return end.timeIntervalSince(start)
        }

        var isCellular = false
        if #available(iOS 13.0, macOS 10.15, *) {
            isCellular = transaction.isCellular
        }

        self.init(
            domainLookup: interval(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connect: interval(transaction.connectStartDate, transaction.connectEndDate),
            secureConnect: interval(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            timeToFirstByte: interval(transaction.requestEndDate, transaction.responseStartDate),
            requestBytesSent: transaction.countOfRequestBodyBytesSent,
            responseBytesReceived: transaction.countOfResponseBodyBytesReceived,
            networkProtocolName: transaction.networkProtocolName,
            isReusedConnection: transaction.isReusedConnection,
            isProxyConnection: transaction.isProxyConnection,
            isCellular: isCellular
        )
    }
}
