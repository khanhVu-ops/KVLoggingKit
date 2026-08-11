import Foundation
import KVLoggingKit

public protocol LogTransport: Sendable {
    func send(_ events: [LogEvent]) async throws
}

/// Lets a transport tell the batching layer that retrying is pointless.
///
/// A rejected API key or a malformed payload fails identically on every
/// attempt, so retrying burns battery and then parks the batch on disk forever.
public protocol RetryableError: Error {
    var isRetryable: Bool { get }
}

extension Error {
    var isRetryableFailure: Bool {
        if let retryable = self as? any RetryableError {
            return retryable.isRetryable
        }
        return true
    }
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
    /// Applied to message and error text before an event leaves the device.
    public var redaction: LogRedaction
    /// Oldest queued batches are discarded once the offline queue exceeds this.
    /// Without a cap, an endpoint that rejects every batch grows the queue until
    /// the device runs out of space.
    public var maxQueuedBatches: Int

    public init(
        maxBatchSize: Int = 50,
        flushInterval: TimeInterval = 10,
        retry: RetryPolicy = .init(),
        redaction: LogRedaction = .default,
        maxQueuedBatches: Int = 200
    ) {
        self.maxBatchSize = max(1, maxBatchSize)
        self.flushInterval = max(0, flushInterval)
        self.retry = retry
        self.redaction = redaction
        self.maxQueuedBatches = max(1, maxQueuedBatches)
    }
}
