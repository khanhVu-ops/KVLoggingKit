import Foundation

/// Intercepts HTTP(S) traffic through `URLProtocol`, the only supported hook
/// that can see both request and response bodies.
///
/// This is the mode to use for in-app API debugging. It costs one extra
/// `URLSession` per request and replays the exchange through a session whose
/// own `protocolClasses` are empty, so interception can never recurse.
///
/// Known limits of `URLProtocol`:
/// - Background sessions ignore custom protocols entirely.
/// - Redirects are followed inside the replay session, so only the final
///   response reaches the record.
/// - The replay session defaults to shared cookie and cache storage. Set
///   ``Settings/replayConfiguration`` when the app configured its own.
public final class NetworkLoggingURLProtocol: URLProtocol, @unchecked Sendable {
    // MARK: - Settings

    public struct Settings: Sendable {
        public var recorder: NetworkLogRecorder
        /// Return `false` to leave a request uncaptured. Use it to exclude the
        /// log-upload endpoint, otherwise uploading logs generates more logs.
        public var shouldCapture: @Sendable (URLRequest) -> Bool
        /// Upper bound on bytes buffered per response before capture stops.
        public var maximumCapturedResponseBytes: Int
        /// Builds the configuration used to replay each intercepted request.
        /// Override it to match the originating session's cookie or cache
        /// storage. `protocolClasses` is always cleared on the result so
        /// interception cannot recurse.
        public var replayConfiguration: @Sendable () -> URLSessionConfiguration

        public init(
            recorder: NetworkLogRecorder = .shared,
            maximumCapturedResponseBytes: Int = 1_048_576,
            shouldCapture: @escaping @Sendable (URLRequest) -> Bool = { _ in true },
            replayConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .default }
        ) {
            self.recorder = recorder
            self.maximumCapturedResponseBytes = max(0, maximumCapturedResponseBytes)
            self.shouldCapture = shouldCapture
            self.replayConfiguration = replayConfiguration
        }
    }

    private static let settingsLock = NSLock()
    nonisolated(unsafe) private static var _settings = Settings()

    public static var settings: Settings {
        get {
            settingsLock.lock()
            defer { settingsLock.unlock() }
            return _settings
        }
        set {
            settingsLock.lock()
            _settings = newValue
            settingsLock.unlock()
        }
    }

    private static let handledKey = "KVLoggingNetwork.handled"

    // MARK: - Installation

    /// Captures every request made by sessions created with `configuration`.
    /// This is the explicit, swizzle-free way to turn capture on.
    public static func install(in configuration: URLSessionConfiguration) {
        var classes = configuration.protocolClasses ?? []
        guard !classes.contains(where: { $0 === NetworkLoggingURLProtocol.self }) else { return }
        classes.insert(NetworkLoggingURLProtocol.self, at: 0)
        configuration.protocolClasses = classes
    }

    /// Registers globally so `URLSession.shared` is captured.
    ///
    /// Sessions built from their own `URLSessionConfiguration` are *not*
    /// covered by `URLProtocol.registerClass` — pass
    /// `swizzlingSessionConfigurations: true` to also capture those. That
    /// exchanges the implementation of `URLSessionConfiguration.protocolClasses`
    /// process-wide, so keep it inside `#if DEBUG`.
    public static func installGlobally(swizzlingSessionConfigurations: Bool = false) {
        URLProtocol.registerClass(NetworkLoggingURLProtocol.self)
        if swizzlingSessionConfigurations {
            _ = swizzleProtocolClassesOnce
        }
    }

    public static func uninstallGlobally() {
        URLProtocol.unregisterClass(NetworkLoggingURLProtocol.self)
    }

    private typealias ProtocolClassesIMP = @convention(c) (AnyObject, Selector) -> [AnyClass]?

    nonisolated(unsafe) private static var originalProtocolClassesIMP: ProtocolClassesIMP?

    private static let swizzleProtocolClassesOnce: Void = {
        // `URLSessionConfiguration.default` is a private concrete subclass, so
        // the getter has to be exchanged on that class, not on the public one.
        let getter = #selector(getter: URLSessionConfiguration.protocolClasses)
        guard
            let concreteClass = object_getClass(URLSessionConfiguration.default),
            let original = class_getInstanceMethod(concreteClass, getter),
            let replacement = class_getInstanceMethod(
                NetworkLoggingURLProtocol.self,
                #selector(NetworkLoggingURLProtocol.kvNetworkLogging_protocolClasses)
            )
        else { return }

        originalProtocolClassesIMP = unsafeBitCast(
            method_getImplementation(original),
            to: ProtocolClassesIMP.self
        )
        method_exchangeImplementations(original, replacement)
    }()

    /// After the exchange this body runs as `protocolClasses`, with `self`
    /// bound to the `URLSessionConfiguration` being queried.
    @objc private func kvNetworkLogging_protocolClasses() -> [AnyClass]? {
        let getter = #selector(getter: URLSessionConfiguration.protocolClasses)
        var classes = NetworkLoggingURLProtocol.originalProtocolClassesIMP?(self, getter) ?? []
        if !classes.contains(where: { $0 === NetworkLoggingURLProtocol.self }) {
            classes.insert(NetworkLoggingURLProtocol.self, at: 0)
        }
        return classes
    }

    // MARK: - URLProtocol

    private var replaySession: URLSession?
    private var replayTask: URLSessionTask?
    private var responseData = Data()
    private var didExceedCaptureLimit = false
    private var capturedResponse: HTTPResponseSnapshot?
    private var capturedMetrics: NetworkLogMetrics?
    private var requestSnapshot: URLRequestSnapshot?
    private var startedAt = Date()

    public override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        guard
            let scheme = request.url?.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return false }
        return settings.shouldCapture(request)
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        startedAt = Date()

        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        // Reading `httpBodyStream` consumes it, so put the bytes back as a plain
        // body before the request goes out.
        var capturedBody = request.httpBody
        if capturedBody == nil, let stream = request.httpBodyStream {
            capturedBody = Self.drain(stream, limit: Self.settings.maximumCapturedResponseBytes)
            mutable.httpBody = capturedBody
            mutable.httpBodyStream = nil
        }

        let outgoing = mutable as URLRequest
        let snapshot = URLRequestSnapshot(outgoing, bodyOverride: capturedBody)
        requestSnapshot = snapshot

        let key = NetworkTaskKey(owner: self, taskIdentifier: 0)
        let recorder = Self.settings.recorder
        let startedAt = startedAt
        Task {
            await recorder.begin(key, request: snapshot, startedAt: startedAt)
        }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "KVLoggingNetwork.replay"

        // An empty protocol list on the replay session makes recursion impossible.
        let configuration = Self.settings.replayConfiguration()
        configuration.protocolClasses = configuration.protocolClasses?.filter {
            $0 !== NetworkLoggingURLProtocol.self
        } ?? []

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        replaySession = session

        let task = session.dataTask(with: outgoing)
        replayTask = task
        task.resume()
    }

    public override func stopLoading() {
        replayTask?.cancel()
        replaySession?.invalidateAndCancel()
        replaySession = nil
        replayTask = nil
    }

    private static func drain(_ stream: InputStream, limit: Int) -> Data? {
        guard limit > 0 else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 8_192
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while stream.hasBytesAvailable, data.count < limit {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

// MARK: - Replay session delegate

extension NetworkLoggingURLProtocol: URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        capturedResponse = HTTPResponseSnapshot(response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let limit = Self.settings.maximumCapturedResponseBytes
        if responseData.count + data.count <= limit {
            responseData.append(data)
        } else {
            didExceedCaptureLimit = true
        }
        client?.urlProtocol(self, didLoad: data)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        capturedMetrics = NetworkLogMetrics(metrics)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let snapshot = requestSnapshot {
            let key = NetworkTaskKey(owner: self, taskIdentifier: 0)
            let recorder = Self.settings.recorder
            let response = capturedResponse ?? HTTPResponseSnapshot(task.response)
            let data = didExceedCaptureLimit ? nil : responseData
            let metrics = capturedMetrics

            Task {
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

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }

        session.finishTasksAndInvalidate()
        replaySession = nil
        replayTask = nil
    }
}
