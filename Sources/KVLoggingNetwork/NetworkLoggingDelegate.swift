import Foundation

/// Observes a `URLSession` through the official delegate API — no swizzling and
/// no request interception.
///
/// Captures method, URL, headers, status, error, and the full
/// `URLSessionTaskMetrics` timing breakdown. From iOS 16 it starts tracking at
/// task creation, so in-flight requests are visible; on earlier releases a
/// record only appears once the task completes.
///
/// Response bodies are only available when the app uses delegate-based data
/// tasks. `session.data(for:)` and the completion-handler overloads consume the
/// data themselves and never call `urlSession(_:dataTask:didReceive:)`. Use
/// ``NetworkLoggingURLProtocol`` when bodies matter.
///
/// Any delegate method this class does not implement is forwarded to
/// `forwardingTo`, so it can wrap an existing delegate transparently.
public final class NetworkLoggingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let recorder: NetworkLogRecorder
    private let wrapped: (any URLSessionDelegate)?
    private let lock = NSLock()
    private var responseBuffers: [Int: Data] = [:]
    private var taskMetrics: [Int: NetworkLogMetrics] = [:]

    public init(
        recorder: NetworkLogRecorder = .shared,
        forwardingTo delegate: (any URLSessionDelegate)? = nil
    ) {
        self.recorder = recorder
        self.wrapped = delegate
        super.init()
    }

    // MARK: - Transparent forwarding

    public override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return wrapped?.responds(to: aSelector) ?? false
    }

    public override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard wrapped?.responds(to: aSelector) == true else { return nil }
        return wrapped
    }

    // MARK: - Capture

    /// Available from iOS 16. On earlier releases there is no task-creation
    /// callback, so records only appear once the task completes.
    @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
    public func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        if let request = task.originalRequest {
            let snapshot = URLRequestSnapshot(request)
            let key = NetworkTaskKey(session: session, taskIdentifier: task.taskIdentifier)
            Task { [recorder] in
                await recorder.begin(key, request: snapshot)
            }
        }

        (wrapped as? URLSessionTaskDelegate)?.urlSession?(session, didCreateTask: task)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        responseBuffers[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()

        (wrapped as? URLSessionDataDelegate)?
            .urlSession?(session, dataTask: dataTask, didReceive: data)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        if let captured = NetworkLogMetrics(metrics) {
            lock.lock()
            taskMetrics[task.taskIdentifier] = captured
            lock.unlock()
        }

        (wrapped as? URLSessionTaskDelegate)?
            .urlSession?(session, task: task, didFinishCollecting: metrics)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let identifier = task.taskIdentifier

        lock.lock()
        let data = responseBuffers.removeValue(forKey: identifier)
        let metrics = taskMetrics.removeValue(forKey: identifier)
        lock.unlock()

        if let request = task.originalRequest {
            let snapshot = URLRequestSnapshot(request)
            let response = HTTPResponseSnapshot(task.response)
            let key = NetworkTaskKey(session: session, taskIdentifier: identifier)

            Task { [recorder] in
                await recorder.complete(
                    key,
                    request: snapshot,
                    response: response,
                    responseData: data,
                    error: error,
                    metrics: metrics
                )
            }
        }

        (wrapped as? URLSessionTaskDelegate)?
            .urlSession?(session, task: task, didCompleteWithError: error)
    }
}

public extension URLSession {
    /// Builds a session that reports every task to `recorder`.
    ///
    /// The returned session owns a ``NetworkLoggingDelegate``; pass the app's
    /// own delegate as `delegate` to keep its behavior.
    static func networkLogging(
        configuration: URLSessionConfiguration = .default,
        recorder: NetworkLogRecorder = .shared,
        delegate: (any URLSessionDelegate)? = nil,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: NetworkLoggingDelegate(recorder: recorder, forwardingTo: delegate),
            delegateQueue: delegateQueue
        )
    }
}
