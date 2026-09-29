import Foundation

private enum LogCommand: Sendable {
    case event(LogEvent)
    /// Already through the processor chain on the calling thread, because an
    /// immediate destination needed it there first. Running it again would
    /// redact twice and, for a stateful processor, count the event twice.
    case processedEvent(LogEvent)
    /// Emitted by the debounce timer to close an open batch.
    case tick
    case flush(CheckedContinuation<Void, Never>)
}

private actor LogWorker {
    private let processors: [any LogProcessor]
    /// Receive batches. Immediate destinations are not among them.
    private let destinations: [any LogDestination]
    /// Receive `flush()`: every destination, immediate ones included.
    private let flushedDestinations: [any LogDestination]
    private let maxBatchSize: Int
    private let batchIntervalNanoseconds: UInt64
    private let internalErrorHandler: (@Sendable (any Error) -> Void)?

    private var batch: [LogEvent] = []
    private var tickTask: Task<Void, Never>?

    init(
        processors: [any LogProcessor],
        destinations: [any LogDestination],
        flushedDestinations: [any LogDestination],
        maxBatchSize: Int,
        batchInterval: TimeInterval,
        internalErrorHandler: (@Sendable (any Error) -> Void)?
    ) {
        self.processors = processors
        self.destinations = destinations
        self.flushedDestinations = flushedDestinations
        self.maxBatchSize = maxBatchSize
        self.batchIntervalNanoseconds = UInt64(max(0, batchInterval) * 1_000_000_000)
        self.internalErrorHandler = internalErrorHandler
        self.batch.reserveCapacity(maxBatchSize)
    }

    /// Runs until the client is deallocated and the stream finishes. It
    /// deliberately does not check `Task.isCancelled`: the previous version
    /// cancelled on `deinit` and dropped whatever was still buffered.
    func consume(
        _ stream: AsyncStream<LogCommand>,
        continuation: AsyncStream<LogCommand>.Continuation
    ) async {
        for await command in stream {
            switch command {
            case let .event(event):
                guard let processed = await process(event) else { continue }
                await accept(processed, continuation: continuation)
            case let .processedEvent(event):
                await accept(event, continuation: continuation)
            case .tick:
                await writeBatch()
            case let .flush(waiter):
                await writeBatch()
                await flushDestinations()
                waiter.resume()
            }
        }

        // The stream only finishes once the client is gone; deliver the tail.
        await writeBatch()
        await flushDestinations()
    }

    private func accept(
        _ event: LogEvent,
        continuation: AsyncStream<LogCommand>.Continuation
    ) async {
        batch.append(event)

        if batch.count >= maxBatchSize {
            await writeBatch()
        } else {
            scheduleTick(continuation: continuation)
        }
    }

    private func process(_ event: LogEvent) async -> LogEvent? {
        var current: LogEvent? = event
        for processor in processors {
            guard let value = current else { return nil }
            current = await processor.process(value)
        }
        return current
    }

    /// One timer per burst, not per event. It routes the wake-up back through
    /// the same channel so batching never reorders events against a flush.
    private func scheduleTick(continuation: AsyncStream<LogCommand>.Continuation) {
        guard tickTask == nil else { return }

        tickTask = Task { [batchIntervalNanoseconds] in
            try? await Task.sleep(nanoseconds: batchIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            continuation.yield(.tick)
        }
    }

    private func writeBatch() async {
        tickTask?.cancel()
        tickTask = nil

        guard !batch.isEmpty else { return }

        let events = batch
        batch.removeAll(keepingCapacity: true)

        for destination in destinations {
            do {
                try await destination.write(events)
            } catch {
                internalErrorHandler?(error)
            }
        }
    }

    private func flushDestinations() async {
        for destination in flushedDestinations {
            do {
                try await destination.flush()
            } catch {
                internalErrorHandler?(error)
            }
        }
    }
}

/// Entry point for logging. Calls are synchronous and never block on I/O.
///
/// Events reach most destinations in batches, on a background worker. An
/// ``ImmediateLogDestination`` — `SystemLogDestination` by default — is written
/// on the calling thread before `log` returns instead, provided every processor
/// is a ``SynchronousLogProcessor``; the processor chain then runs on the
/// calling thread too, once, and the batched destinations get its result.
public final class LogClient: @unchecked Sendable {
    public static let disabled = LogClient(
        configuration: .init(minimumLevel: .critical),
        destinations: [],
        isEnabled: false
    )

    private let isEnabled: Bool
    private let commandContinuation: AsyncStream<LogCommand>.Continuation
    private let workerTask: Task<Void, Never>

    /// Empty unless every processor is synchronous; see the type's docs.
    private let immediateDestinations: [any ImmediateLogDestination]
    private let synchronousProcessors: [any SynchronousLogProcessor]
    private let hasBatchedDestinations: Bool

    private let levelLock = NSLock()
    private var _minimumLevel: LogLevel
    private var _droppedEventCount = 0

    public convenience init(
        configuration: LogConfiguration = .init(),
        destinations: [any LogDestination]
    ) {
        self.init(
            configuration: configuration,
            destinations: destinations,
            isEnabled: true
        )
    }

    private init(
        configuration: LogConfiguration,
        destinations: [any LogDestination],
        isEnabled: Bool
    ) {
        self._minimumLevel = configuration.minimumLevel
        self.isEnabled = isEnabled

        let synchronousProcessors = configuration.processors.compactMap {
            $0 as? any SynchronousLogProcessor
        }
        // One async processor anywhere in the chain means the chain can only
        // run on the worker, so nothing may be written before it has.
        let canWriteImmediately = synchronousProcessors.count == configuration.processors.count

        var immediateDestinations: [any ImmediateLogDestination] = []
        var batchedDestinations: [any LogDestination] = []
        for destination in destinations {
            if canWriteImmediately,
               let immediate = destination as? any ImmediateLogDestination,
               immediate.writesImmediately {
                immediateDestinations.append(immediate)
            } else {
                batchedDestinations.append(destination)
            }
        }
        self.immediateDestinations = immediateDestinations
        self.synchronousProcessors = synchronousProcessors
        self.hasBatchedDestinations = !batchedDestinations.isEmpty

        // Bounded so a logging storm cannot grow without limit. Overflow drops
        // the oldest pending events, which are the least useful ones.
        let stream = AsyncStream<LogCommand>.makeStream(
            bufferingPolicy: .bufferingNewest(configuration.maximumBufferedEvents)
        )
        commandContinuation = stream.continuation

        let worker = LogWorker(
            processors: configuration.processors,
            destinations: batchedDestinations,
            flushedDestinations: destinations,
            maxBatchSize: configuration.maxBatchSize,
            batchInterval: configuration.batchInterval,
            internalErrorHandler: configuration.internalErrorHandler
        )
        workerTask = Task {
            await worker.consume(stream.stream, continuation: stream.continuation)
        }
    }

    deinit {
        // Finish without cancelling so the worker drains what is still queued.
        commandContinuation.finish()
    }

    // MARK: - Level

    /// Adjustable at runtime, so a debug menu can raise verbosity in a build
    /// that shipped at `.info` without relaunching.
    public var minimumLevel: LogLevel {
        get {
            levelLock.lock()
            defer { levelLock.unlock() }
            return _minimumLevel
        }
        set {
            levelLock.lock()
            _minimumLevel = newValue
            levelLock.unlock()
        }
    }

    /// Events discarded because the buffer was full. Non-zero means the app is
    /// logging faster than the destinations can drain.
    public var droppedEventCount: Int {
        levelLock.lock()
        defer { levelLock.unlock() }
        return _droppedEventCount
    }

    // MARK: - Logging

    public func log(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        category: String? = nil,
        metadata: LogMetadata = [:],
        error: (any Error)? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        guard isEnabled, level >= minimumLevel else { return }

        let event = LogEvent(
            level: level,
            message: message(),
            category: category,
            metadata: metadata,
            error: error,
            source: .init(file: file, function: function, line: line)
        )

        guard !immediateDestinations.isEmpty else {
            handle(commandContinuation.yield(.event(event)))
            return
        }

        guard let processed = processSynchronously(event) else { return }

        for destination in immediateDestinations {
            destination.writeImmediately(processed)
        }
        if hasBatchedDestinations {
            handle(commandContinuation.yield(.processedEvent(processed)))
        }
    }

    private func processSynchronously(_ event: LogEvent) -> LogEvent? {
        var current = event
        for processor in synchronousProcessors {
            guard let next = processor.processSynchronously(current) else { return nil }
            current = next
        }
        return current
    }

    /// Overflow evicts the oldest queued command. If that command happens to be
    /// a pending `flush`, its continuation has to be resumed here or the caller
    /// awaits forever.
    private func handle(_ result: AsyncStream<LogCommand>.Continuation.YieldResult) {
        guard case let .dropped(command) = result else { return }

        if case let .flush(waiter) = command {
            waiter.resume()
        } else {
            levelLock.lock()
            _droppedEventCount += 1
            levelLock.unlock()
        }
    }

    public func trace(
        _ message: @autoclosure () -> String,
        category: String? = nil,
        metadata: LogMetadata = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.trace, message(), category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public func debug(
        _ message: @autoclosure () -> String,
        category: String? = nil,
        metadata: LogMetadata = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.debug, message(), category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public func info(
        _ message: @autoclosure () -> String,
        category: String? = nil,
        metadata: LogMetadata = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.info, message(), category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public func notice(
        _ message: @autoclosure () -> String,
        category: String? = nil,
        metadata: LogMetadata = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.notice, message(), category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public func warning(
        _ message: @autoclosure () -> String,
        category: String? = nil,
        metadata: LogMetadata = [:],
        error: (any Error)? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.warning, message(), category: category, metadata: metadata, error: error, file: file, function: function, line: line)
    }

    public func error(
        _ message: @autoclosure () -> String,
        category: String? = nil,
        metadata: LogMetadata = [:],
        error: (any Error)? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.error, message(), category: category, metadata: metadata, error: error, file: file, function: function, line: line)
    }

    public func critical(
        _ message: @autoclosure () -> String,
        category: String? = nil,
        metadata: LogMetadata = [:],
        error: (any Error)? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.critical, message(), category: category, metadata: metadata, error: error, file: file, function: function, line: line)
    }

    /// Writes everything buffered and flushes each destination.
    public func flush() async {
        guard isEnabled else { return }

        await withCheckedContinuation { continuation in
            let result = commandContinuation.yield(.flush(continuation))
            if case .terminated = result {
                continuation.resume()
            } else {
                handle(result)
            }
        }
    }

    public func scoped(
        category: String? = nil,
        metadata: LogMetadata = [:]
    ) -> ScopedLogClient {
        ScopedLogClient(client: self, category: category, metadata: metadata)
    }
}
