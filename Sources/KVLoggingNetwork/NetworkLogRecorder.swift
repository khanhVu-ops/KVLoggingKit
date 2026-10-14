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
    private var streams: [NetworkTaskKey: StreamCapture] = [:]
    private let maximumStreamEvents: Int
    private let streamPublishInterval: TimeInterval

    private struct StreamCapture {
        var parser = ServerSentEventParser()
        var lastPublish = Date.distantPast
        var isFlushScheduled = false
    }

    /// - Parameters:
    ///   - maximumStreamEvents: Events kept per server-sent events response.
    ///     Older ones are dropped first and counted in
    ///     ``NetworkStreamLog/droppedEventCount``.
    ///   - streamPublishInterval: How often a live stream pushes its new events
    ///     to the store. Token-by-token streams would otherwise refresh the
    ///     viewer hundreds of times a second.
    public init(
        store: NetworkLogStore = .shared,
        redactor: NetworkLogRedactor = .default,
        logger: LogClient? = nil,
        category: String = "network",
        isEnabled: Bool = true,
        maximumStreamEvents: Int = 2_000,
        streamPublishInterval: TimeInterval = 0.25
    ) {
        self.store = store
        self.redactor = redactor
        self.logger = logger
        self.category = category
        self.isEnabled = isEnabled
        self.maximumStreamEvents = max(1, maximumStreamEvents)
        self.streamPublishInterval = max(0, streamPublishInterval)
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
            streams.removeAll()
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

    /// Records the response head as soon as it arrives, so a long-lived
    /// response shows its status and headers while still in flight. A
    /// `text/event-stream` response starts collecting events from here on.
    public func receive(
        _ key: NetworkTaskKey,
        response: HTTPResponseSnapshot
    ) async {
        guard isEnabled, var record = inFlight[key] else { return }

        record.response = NetworkLogResponse(
            statusCode: response.statusCode,
            headers: redactor.redacted(headers: response.headers),
            body: NetworkLogBody(content: .empty, contentType: response.contentType)
        )
        if NetworkLogRecord.isEventStream(contentType: response.contentType) {
            record.stream = NetworkStreamLog()
            streams[key] = StreamCapture()
        }
        inFlight[key] = record
        await store.update(record)
    }

    /// Feeds a chunk of a `text/event-stream` body. Ignored for any other response.
    public func receiveStreamData(
        _ key: NetworkTaskKey,
        data: Data,
        receivedAt: Date = Date()
    ) async {
        guard
            isEnabled,
            var record = inFlight[key],
            var stream = record.stream,
            var capture = streams[key]
        else { return }

        stream.totalByteCount += data.count
        let offset = receivedAt.timeIntervalSince(record.startedAt)
        for fields in capture.parser.feed(data) {
            append(fields, offset: offset, to: &stream)
        }
        record.stream = stream
        inFlight[key] = record

        if receivedAt.timeIntervalSince(capture.lastPublish) >= streamPublishInterval {
            capture.lastPublish = receivedAt
            streams[key] = capture
            await store.update(record)
        } else if !capture.isFlushScheduled {
            // Events that arrive inside the interval still have to show up if
            // the stream then goes quiet.
            capture.isFlushScheduled = true
            streams[key] = capture
            let delay = UInt64(streamPublishInterval * 1_000_000_000)
            Task {
                try? await Task.sleep(nanoseconds: delay)
                await self.flushStream(key)
            }
        } else {
            streams[key] = capture
        }
    }

    private func flushStream(_ key: NetworkTaskKey) async {
        guard var capture = streams[key], let record = inFlight[key] else { return }
        capture.isFlushScheduled = false
        capture.lastPublish = Date()
        streams[key] = capture
        await store.update(record)
    }

    private func append(
        _ fields: ServerSentEventFields,
        offset: TimeInterval,
        to stream: inout NetworkStreamLog
    ) {
        let event = redactor.streamEvent(from: fields, id: stream.totalEventCount, offset: offset)
        stream.totalEventCount += 1
        stream.events.append(event)

        let overflow = stream.events.count - maximumStreamEvents
        if overflow > 0 {
            stream.events.removeFirst(overflow)
            stream.droppedEventCount += overflow
        }
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

        var capture = streams.removeValue(forKey: key)

        if let response {
            let body: NetworkLogBody
            if NetworkLogRecord.isEventStream(contentType: response.contentType) {
                var stream = record.stream ?? NetworkStreamLog()
                if capture == nil {
                    // Nothing was fed live (delegate mode): parse the whole body now.
                    var parser = ServerSentEventParser()
                    let data = responseData ?? Data()
                    stream.totalByteCount = data.count
                    let offset = record.duration ?? 0
                    for fields in parser.feed(data) {
                        append(fields, offset: offset, to: &stream)
                    }
                    capture = StreamCapture(parser: parser)
                }
                if let last = capture?.parser.finish() {
                    append(last, offset: record.duration ?? 0, to: &stream)
                }
                record.stream = stream
                body = rawBody(for: stream, contentType: response.contentType)
            } else {
                body = redactor.responseBody(from: responseData, contentType: response.contentType)
            }

            record.response = NetworkLogResponse(
                statusCode: response.statusCode,
                headers: redactor.redacted(headers: response.headers),
                body: body
            )
        }

        record.state = (error == nil && record.isSuccess) ? .succeeded : .failed

        await store.update(record)
        emitEvent(for: record, error: error)
    }

    // MARK: - Helpers

    /// The stream written back out from its redacted events, so the raw view
    /// never shows a value the event list hides.
    private func rawBody(for stream: NetworkStreamLog, contentType: String?) -> NetworkLogBody {
        guard redactor.capturesResponseBodies else {
            return redactor.responseBody(from: nil, contentType: contentType)
        }
        guard !stream.events.isEmpty else {
            return NetworkLogBody(content: .empty, byteCount: stream.totalByteCount, contentType: contentType)
        }

        var text = ""
        var isTruncated = stream.droppedEventCount > 0
        for event in stream.events {
            var block = ""
            if let name = event.event { block += "event: \(name)\n" }
            if let id = event.lastEventID { block += "id: \(id)\n" }
            block += event.data.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "data: \($0)\n" }
                .joined()
            block += "\n"

            if text.utf8.count + block.utf8.count > redactor.maximumBodyByteCount {
                isTruncated = true
                break
            }
            text += block
        }

        return NetworkLogBody(
            content: .text(text),
            byteCount: stream.totalByteCount,
            isTruncated: isTruncated,
            contentType: contentType
        )
    }

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
