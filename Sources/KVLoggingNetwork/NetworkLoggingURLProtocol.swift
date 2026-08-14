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
    /// replaces the implementation of `URLSessionConfiguration.protocolClasses`
    /// process-wide and for the life of the process — ``uninstallGlobally()``
    /// unregisters the protocol but cannot undo the replacement — so keep it
    /// inside `#if DEBUG`.
    public static func installGlobally(swizzlingSessionConfigurations: Bool = false) {
        URLProtocol.registerClass(NetworkLoggingURLProtocol.self)
        if swizzlingSessionConfigurations {
            _ = swizzleProtocolClassesOnce
        }
    }

    public static func uninstallGlobally() {
        URLProtocol.unregisterClass(NetworkLoggingURLProtocol.self)
    }

    /// Matches the real getter's contract: an ObjC method handing back `NSArray *`
    /// at +0, autoreleased.
    ///
    /// Declaring the return as a bridged `[AnyClass]?` instead is what made the
    /// first version of this crash — see ``swizzleProtocolClassesOnce``.
    typealias ProtocolClassesIMP =
        @convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>?

    // Internal, not private, so the regression test can drive the replacement
    // with a stub chain instead of installing the real swizzle — which is
    // process-global and cannot be undone.
    nonisolated(unsafe) static var originalProtocolClassesIMP: ProtocolClassesIMP?

    /// Runs as `protocolClasses` once installed, with `received` bound to the
    /// `URLSessionConfiguration` being queried.
    ///
    /// A free C function rather than an `@objc` method on this class: see
    /// ``swizzleProtocolClassesOnce`` for why that distinction is the whole bug.
    /// It captures nothing — `@convention(c)` forbids it — and reaches the saved
    /// implementation through the static above.
    static let protocolClassesReplacement: ProtocolClassesIMP = { received, selector in
        let inherited = originalProtocolClassesIMP?(received, selector)?
            .takeUnretainedValue() ?? NSArray()
        let existing = inherited as? [AnyClass] ?? []

        guard !existing.contains(where: { $0 === NetworkLoggingURLProtocol.self }) else {
            return Unmanaged.passRetained(inherited).autorelease()
        }

        let combined = NSArray(
            array: [NetworkLoggingURLProtocol.self] + existing
        )
        // +0 autoreleased, as an ObjC getter returns. Handing back a retained
        // object here leaks; handing back an unretained temporary over-releases.
        return Unmanaged.passRetained(combined).autorelease()
    }

    /// Adds this protocol to every `URLSessionConfiguration`'s `protocolClasses`.
    ///
    /// The first version of this exchanged the getter with an `@objc` method on
    /// this class that returned a bridged `[AnyClass]?`. That crashed every app
    /// that enabled it on iOS 26:
    ///
    /// ```
    /// +[NSURLSessionConfiguration canInitWithTask:]: unrecognized selector
    ///   sent to class
    ///   -[__NSURLSessionLocal _protocolClassForTask:skipAppSSO:]  (CFNetwork)
    /// ```
    ///
    /// The list it produced was corrupt. The protocol class did not survive the
    /// return — it read back as `NSURLSessionConfiguration`, which is not a
    /// `URLProtocol` subclass and answers neither `+canInitWithTask:` nor
    /// `+canInitWithRequest:` — and one more bogus entry was prepended on every
    /// read, so the list grew without bound. CFNetwork asks every entry whether it
    /// can handle the task, so the first request through any session built from
    /// its own configuration terminated the process. Interception never worked
    /// either: the protocol appeared in the list zero times.
    ///
    /// Two things fix it, both required:
    ///
    /// - The replacement is a free C function returning `NSArray` at +0. A Swift
    ///   `@objc` method is the wrong tool: its thunk is entitled to assume `self`
    ///   is an instance of the class that declares it, and here `self` is a
    ///   configuration. The bridged `[AnyClass]?` return is what corrupted the
    ///   list — an exchange with a C function of the right signature is clean.
    /// - `class_replaceMethod`, not `method_exchangeImplementations`.
    ///   `class_getInstanceMethod` walks up the superclass chain, so exchanging
    ///   what it returns edits whichever class actually declares the getter —
    ///   process-wide, above the one we targeted. `class_replaceMethod` adds the
    ///   method to the class we name when the implementation is inherited, so a
    ///   superclass is never touched. (On iOS 26 `URLSessionConfiguration.default`
    ///   is a plain `NSURLSessionConfiguration`, not the private subclass this
    ///   code once assumed, so the two happened to coincide — but that is an
    ///   implementation detail to not depend on.)
    private static let swizzleProtocolClassesOnce: Void = {
        let getter = #selector(getter: URLSessionConfiguration.protocolClasses)
        guard
            let concreteClass = object_getClass(URLSessionConfiguration.default),
            let method = class_getInstanceMethod(concreteClass, getter)
        else { return }

        // Captured before installing, and it has to be: the replacement chains
        // through this to get Foundation's real protocol classes, and a window
        // where it is installed but the chain is unset would answer with this
        // protocol alone — dropping `_NSURLHTTPProtocol` and the rest, i.e.
        // breaking all networking rather than logging it.
        //
        // `class_getInstanceMethod` already resolved inheritance, so this is the
        // effective implementation whether the getter is declared on this class
        // or above it. Either way `class_replaceMethod` leaves it reachable:
        // an inherited one stays on its own class untouched, and a displaced one
        // is still a live function.
        originalProtocolClassesIMP = unsafeBitCast(
            method_getImplementation(method),
            to: ProtocolClassesIMP.self
        )

        class_replaceMethod(
            concreteClass,
            getter,
            unsafeBitCast(protocolClassesReplacement, to: IMP.self),
            method_getTypeEncoding(method)
        )
    }()

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
