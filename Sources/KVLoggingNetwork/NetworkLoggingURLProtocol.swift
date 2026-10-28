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
            _replaySession = nil
            settingsLock.unlock()
        }
    }

    // MARK: - Replay session

    /// One replay session for every intercepted request, alive for the life of
    /// the process.
    ///
    /// Up to 1.2.0 each request built its own session and invalidated it on
    /// completion. That crashed on iOS 26 with `EXC_BAD_ACCESS` in
    /// `objc_retain`, on `com.apple.network.connections`:
    ///
    /// ```
    /// -[NSURLSessionTask session]
    /// -[__NSCFLocalSessionTask dealloc]
    /// URLProtocol::~URLProtocol()
    /// ...
    /// -[NWConcrete_nw_path_evaluator dealloc]
    /// nw_association_schedule_deactivation
    /// ```
    ///
    /// Network.framework keeps the connection — and through it the task — for a
    /// while after the task completes, then tears it down on its own queue. A
    /// task does not keep its session alive, so by then a throwaway session had
    /// already been deallocated and the task's dealloc read a dangling pointer.
    /// It needed a request to finish and its connection to be retired later, so
    /// it showed up after a few uploads, never on the first request.
    ///
    /// A session that is never released cannot dangle. Changing ``settings``
    /// starts a new one for later requests; the old one is kept in
    /// `retiredReplaySessions`, not invalidated, for the same reason.
    nonisolated(unsafe) private static var _replaySession: URLSession?
    nonisolated(unsafe) private static var retiredReplaySessions: [URLSession] = []
    private static let replayRouter = ReplayRouter()

    // Internal, not private, so the regression test can check the session is reused.
    static func replaySession() -> URLSession {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        if let session = _replaySession { return session }

        // An empty protocol list on the replay session makes recursion impossible.
        let configuration = _settings.replayConfiguration()
        configuration.protocolClasses = configuration.protocolClasses?.filter {
            $0 !== NetworkLoggingURLProtocol.self
        } ?? []

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "KVLoggingNetwork.replay"

        let session = URLSession(configuration: configuration, delegate: replayRouter, delegateQueue: queue)
        _replaySession = session
        retiredReplaySessions.append(session)
        return session
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

    private var replayTask: URLSessionTask?
    private var responseData = Data()
    private var didExceedCaptureLimit = false
    private var capturedResponse: HTTPResponseSnapshot?
    private var capturedMetrics: NetworkLogMetrics?
    private var requestSnapshot: URLRequestSnapshot?
    private var startedAt = Date()
    private var isEventStream = false
    private var captureSteps: AsyncStream<CaptureStep>.Continuation?

    /// Capture callbacks, in the order the replay session delivered them.
    ///
    /// One `Task` per callback would race: a stream's chunks could reach the
    /// recorder out of order, or after the exchange was already completed.
    private enum CaptureStep: Sendable {
        case begin(URLRequestSnapshot, Date)
        case response(HTTPResponseSnapshot)
        case streamData(Data, Date)
        case complete(
            URLRequestSnapshot,
            HTTPResponseSnapshot?,
            Data?,
            (any Error)?,
            NetworkLogMetrics?
        )
    }

    private func startCapturePipeline(recorder: NetworkLogRecorder) {
        var continuation: AsyncStream<CaptureStep>.Continuation?
        let steps = AsyncStream<CaptureStep>(bufferingPolicy: .unbounded) { continuation = $0 }
        captureSteps = continuation

        let key = NetworkTaskKey(owner: self, taskIdentifier: 0)
        Task {
            for await step in steps {
                switch step {
                case let .begin(snapshot, startedAt):
                    await recorder.begin(key, request: snapshot, startedAt: startedAt)
                case let .response(response):
                    await recorder.receive(key, response: response)
                case let .streamData(data, receivedAt):
                    await recorder.receiveStreamData(key, data: data, receivedAt: receivedAt)
                case let .complete(snapshot, response, data, error, metrics):
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
        }
    }

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

        // URLSession hands a protocol the body as a stream even when the caller set
        // `httpBody`. Reading it consumes it, so the whole body is read and put back
        // as a plain body before the request goes out. Two rules, both learned the
        // hard way in 1.1.0:
        // - read to end of stream, never on `hasBytesAvailable`, which can read
        //   `false` before the stream has delivered anything;
        // - the capture limit bounds only what is *recorded*. It once bounded what
        //   was *sent*, truncating every upload past 1 MB.
        var outgoingBody = request.httpBody
        if outgoingBody == nil, let stream = request.httpBodyStream {
            guard let body = Self.readToEnd(stream) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
                return
            }
            outgoingBody = body
            // Order matters: `httpBody` and `httpBodyStream` are exclusive, and
            // assigning the stream — even `nil` — clears the body. 1.1.0 set the
            // body first and the stream second, sending an empty body every time.
            mutable.httpBodyStream = nil
            mutable.httpBody = body
        }

        let limit = Self.settings.maximumCapturedResponseBytes
        let recordedBody = outgoingBody.map { $0.count > limit ? $0.prefix(limit) : $0 }

        let outgoing = mutable as URLRequest
        let snapshot = URLRequestSnapshot(outgoing, bodyOverride: recordedBody)
        requestSnapshot = snapshot

        startCapturePipeline(recorder: Self.settings.recorder)
        captureSteps?.yield(.begin(snapshot, startedAt))

        let task = Self.replaySession().dataTask(with: outgoing)
        Self.replayRouter.register(self, for: task)
        replayTask = task
        task.resume()
    }

    public override func stopLoading() {
        // Cancelling the replay task still reports completion through the
        // delegate, which closes the capture pipeline.
        replayTask?.cancel()
        replayTask = nil
    }

    /// Every byte of `stream`, or `nil` if the stream fails part-way — a request
    /// must not go out with a silently shortened body.
    static func readToEnd(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 64 * 1_024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else if read == 0 {
                return data
            } else {
                return nil
            }
        }
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
        let snapshot = HTTPResponseSnapshot(response)
        capturedResponse = snapshot
        if let snapshot {
            isEventStream = NetworkLogRecord.isEventStream(contentType: snapshot.contentType)
            captureSteps?.yield(.response(snapshot))
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        if isEventStream {
            // Parsed as it arrives instead of buffered: a stream can stay open
            // for minutes, and the console shows its events live.
            captureSteps?.yield(.streamData(data, Date()))
            client?.urlProtocol(self, didLoad: data)
            return
        }

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
            let response = capturedResponse ?? HTTPResponseSnapshot(task.response)
            let data = didExceedCaptureLimit ? nil : responseData
            captureSteps?.yield(.complete(snapshot, response, data, error, capturedMetrics))
        }
        captureSteps?.finish()
        captureSteps = nil

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }

        replayTask = nil
    }
}

// MARK: - Replay router

/// Delegate of the shared replay session: hands each callback to the protocol
/// instance that started the task, and holds that instance until the task
/// completes — what the per-request session's strong delegate used to do.
private final class ReplayRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [Int: NetworkLoggingURLProtocol] = [:]

    func register(_ owner: NetworkLoggingURLProtocol, for task: URLSessionTask) {
        lock.lock()
        owners[task.taskIdentifier] = owner
        lock.unlock()
    }

    private func owner(of task: URLSessionTask, removing: Bool = false) -> NetworkLoggingURLProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return removing ? owners.removeValue(forKey: task.taskIdentifier) : owners[task.taskIdentifier]
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let owner = owner(of: dataTask) else { return completionHandler(.cancel) }
        owner.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner(of: dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        owner(of: task)?.urlSession(session, task: task, didFinishCollecting: metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        owner(of: task, removing: true)?.urlSession(session, task: task, didCompleteWithError: error)
    }
}
