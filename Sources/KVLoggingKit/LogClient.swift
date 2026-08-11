import Foundation

private enum LogCommand: Sendable {
    case event(LogEvent)
    case flush(CheckedContinuation<Void, Never>)
}

private actor LogWorker {
    private let processors: [any LogProcessor]
    private let destinations: [any LogDestination]
    private let internalErrorHandler: (@Sendable (any Error) -> Void)?

    init(
        processors: [any LogProcessor],
        destinations: [any LogDestination],
        internalErrorHandler: (@Sendable (any Error) -> Void)?
    ) {
        self.processors = processors
        self.destinations = destinations
        self.internalErrorHandler = internalErrorHandler
    }

    func consume(_ stream: AsyncStream<LogCommand>) async {
        for await command in stream {
            if Task.isCancelled { break }

            switch command {
            case let .event(event):
                await process(event)
            case let .flush(continuation):
                await flushDestinations()
                continuation.resume()
            }
        }
    }

    private func process(_ initialEvent: LogEvent) async {
        var currentEvent: LogEvent? = initialEvent

        for processor in processors {
            guard let event = currentEvent else { return }
            currentEvent = await processor.process(event)
        }

        guard let event = currentEvent else { return }

        for destination in destinations {
            do {
                try await destination.write([event])
            } catch {
                internalErrorHandler?(error)
            }
        }
    }

    private func flushDestinations() async {
        for destination in destinations {
            do {
                try await destination.flush()
            } catch {
                internalErrorHandler?(error)
            }
        }
    }
}

public final class LogClient: @unchecked Sendable {
    public static let disabled = LogClient(
        configuration: .init(minimumLevel: .critical),
        destinations: [],
        isEnabled: false
    )

    private let minimumLevel: LogLevel
    private let isEnabled: Bool
    private let commandContinuation: AsyncStream<LogCommand>.Continuation
    private let workerTask: Task<Void, Never>

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
        self.minimumLevel = configuration.minimumLevel
        self.isEnabled = isEnabled

        let stream = AsyncStream<LogCommand>.makeStream()
        commandContinuation = stream.continuation

        let worker = LogWorker(
            processors: configuration.processors,
            destinations: destinations,
            internalErrorHandler: configuration.internalErrorHandler
        )
        workerTask = Task {
            await worker.consume(stream.stream)
        }
    }

    deinit {
        commandContinuation.finish()
        workerTask.cancel()
    }

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

        commandContinuation.yield(
            .event(
                LogEvent(
                    level: level,
                    message: message(),
                    category: category,
                    metadata: metadata,
                    error: error,
                    source: .init(file: file, function: function, line: line)
                )
            )
        )
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

    public func flush() async {
        guard isEnabled else { return }

        await withCheckedContinuation { continuation in
            let result = commandContinuation.yield(.flush(continuation))
            if case .terminated = result {
                continuation.resume()
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
