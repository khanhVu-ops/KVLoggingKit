import Foundation
import KVLoggingKit

/// Turns raw capture callbacks into redacted records plus one `LogEvent` per
/// finished exchange.
///
/// Bodies and headers stay inside `NetworkLogStore` for the in-app viewer. The
/// `LogEvent` carries only method, host, path, status, and duration, so
/// enabling network logging never widens what remote destinations receive.
public actor NetworkLogRecorder {
    public static let shared = NetworkLogRecorder()

    private let store: NetworkLogStore
    private var redactor: NetworkLogRedactor
    private var logger: LogClient?
    private var category: String
    private var isEnabled: Bool
    private var inFlight: [NetworkTaskKey: NetworkLogRecord] = [:]

    public init(
        store: NetworkLogStore = .shared,
        redactor: NetworkLogRedactor = .default,
        logger: LogClient? = nil,
        category: String = "network",
        isEnabled: Bool = true
    ) {
        self.store = store
        self.redactor = redactor
        self.logger = logger
        self.category = category
        self.isEnabled = isEnabled
    }

    // MARK: - Configuration

    public func setLogger(_ logger: LogClient?) {
        self.logger = logger
    }

    public func setRedactor(_ redactor: NetworkLogRedactor) {
        self.redactor = redactor
    }

    public func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        if !isEnabled {
            inFlight.removeAll()
        }
    }

    // MARK: - Capture

    /// Records a task that has just started. Only interception modes that see
    /// task creation call this; delegate mode records on completion instead.
    @discardableResult
    public func begin(
        _ key: NetworkTaskKey,
        request: URLRequestSnapshot,
        startedAt: Date = Date()
    ) async -> UUID? {
        guard isEnabled else { return nil }

        let record = NetworkLogRecord(
            startedAt: startedAt,
            state: .pending,
            request: makeRequest(from: request)
        )
        inFlight[key] = record
        await store.insert(record)
        return record.id
    }

    /// Finishes a task, whether or not `begin` was called for it.
    public func complete(
        _ key: NetworkTaskKey,
        request: URLRequestSnapshot,
        response: HTTPResponseSnapshot?,
        responseData: Data?,
        error: (any Error)?,
        metrics: NetworkLogMetrics?,
        finishedAt: Date = Date()
    ) async {
        guard isEnabled else { return }

        var record = inFlight.removeValue(forKey: key)
            ?? NetworkLogRecord(startedAt: finishedAt, request: makeRequest(from: request))

        record.request = makeRequest(from: request)
        record.duration = finishedAt.timeIntervalSince(record.startedAt)
        record.metrics = metrics
        record.error = error.map(LogError.init)

        if let response {
            record.response = NetworkLogResponse(
                statusCode: response.statusCode,
                headers: redactor.redacted(headers: response.headers),
                body: redactor.responseBody(
                    from: responseData,
                    contentType: response.contentType
                )
            )
        }

        record.state = (error == nil && record.isSuccess) ? .succeeded : .failed

        await store.update(record)
        emitEvent(for: record, error: error)
    }

    // MARK: - Helpers

    private func makeRequest(from snapshot: URLRequestSnapshot) -> NetworkLogRequest {
        NetworkLogRequest(
            method: snapshot.method.uppercased(),
            url: redactor.redactedURLString(snapshot.url),
            host: snapshot.url?.host,
            path: snapshot.url?.path,
            headers: redactor.redacted(headers: snapshot.headers),
            body: redactor.requestBody(
                from: snapshot.body,
                contentType: snapshot.contentType,
                hasUncapturableStream: snapshot.hasUncapturableStream
            ),
            timeout: snapshot.timeout
        )
    }

    private func emitEvent(for record: NetworkLogRecord, error: (any Error)?) {
        guard let logger else { return }

        var metadata: LogMetadata = [
            "http_method": .public(record.request.method),
            "request_id": .public(record.id)
        ]
        if let host = record.request.host {
            metadata["http_host"] = .public(host)
        }
        if let path = record.request.path {
            metadata["http_path"] = .public(path)
        }
        if let statusCode = record.statusCode {
            metadata["http_status"] = .public(statusCode)
        }
        if let duration = record.duration {
            metadata["duration_ms"] = .public(Int(duration * 1_000))
        }
        if let bytes = record.metrics?.responseBytesReceived, bytes > 0 {
            metadata["response_bytes"] = .public(Int(bytes))
        }

        logger.log(
            level(for: record),
            record.summary,
            category: category,
            metadata: metadata,
            error: error
        )
    }

    private func level(for record: NetworkLogRecord) -> LogLevel {
        if record.error != nil { return .error }
        switch record.statusCode {
        case .some(500...): return .error
        case .some(400..<500): return .warning
        default: return .info
        }
    }
}
