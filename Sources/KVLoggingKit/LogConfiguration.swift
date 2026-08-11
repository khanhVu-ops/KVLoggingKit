import Foundation

public struct LogConfiguration: Sendable {
    public var minimumLevel: LogLevel
    public var processors: [any LogProcessor]
    public var internalErrorHandler: (@Sendable (any Error) -> Void)?

    /// Events are handed to destinations in groups of at most this size, so a
    /// file destination pays one write per group instead of one per line.
    public var maxBatchSize: Int
    /// How long an incomplete batch waits for company before being written.
    /// Small enough to feel immediate, large enough to coalesce a burst.
    public var batchInterval: TimeInterval
    /// Ceiling on events waiting to be processed. Beyond it the oldest are
    /// dropped and counted in `LogClient.droppedEventCount`.
    public var maximumBufferedEvents: Int

    public init(
        minimumLevel: LogLevel = .trace,
        processors: [any LogProcessor] = [],
        internalErrorHandler: (@Sendable (any Error) -> Void)? = nil,
        maxBatchSize: Int = 64,
        batchInterval: TimeInterval = 0.2,
        maximumBufferedEvents: Int = 10_000
    ) {
        self.minimumLevel = minimumLevel
        self.processors = processors
        self.internalErrorHandler = internalErrorHandler
        self.maxBatchSize = max(1, maxBatchSize)
        self.batchInterval = max(0, batchInterval)
        self.maximumBufferedEvents = max(1, maximumBufferedEvents)
    }

    public static let production = LogConfiguration(minimumLevel: .info)
}
