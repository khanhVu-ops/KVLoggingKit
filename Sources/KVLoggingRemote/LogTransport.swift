import Foundation
import KVLoggingKit

public protocol LogTransport: Sendable {
    func send(_ events: [LogEvent]) async throws
}

public struct RetryPolicy: Sendable {
    public var maximumAttempts: Int
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval

    public init(
        maximumAttempts: Int = 3,
        initialDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 60
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialDelay = max(0, initialDelay)
        self.maximumDelay = max(0, maximumDelay)
    }
}

public struct RemoteBatchPolicy: Sendable {
    public var maxBatchSize: Int
    public var flushInterval: TimeInterval
    public var retry: RetryPolicy

    public init(
        maxBatchSize: Int = 50,
        flushInterval: TimeInterval = 10,
        retry: RetryPolicy = .init()
    ) {
        self.maxBatchSize = max(1, maxBatchSize)
        self.flushInterval = max(0, flushInterval)
        self.retry = retry
    }
}
