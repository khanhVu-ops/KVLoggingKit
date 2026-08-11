import Foundation
import KVLoggingKit

public actor RemoteBatchDestination: LogDestination {
    private let transport: any LogTransport
    private let queue: any LogBatchQueue
    private let policy: RemoteBatchPolicy
    private var pending: [LogEvent] = []
    private var scheduledFlush: Task<Void, Never>?

    public init(
        transport: any LogTransport,
        queue: any LogBatchQueue = MemoryLogBatchQueue(),
        policy: RemoteBatchPolicy = .init()
    ) {
        self.transport = transport
        self.queue = queue
        self.policy = policy
    }

    public func write(_ events: [LogEvent]) async throws {
        pending.append(
            contentsOf: events.map { $0.redactedForRemote(scrubbing: policy.redaction) }
        )

        if pending.count >= policy.maxBatchSize {
            scheduledFlush?.cancel()
            scheduledFlush = nil
            try await drainPending(fullBatchesOnly: true)
        } else {
            scheduleFlushIfNeeded()
        }
    }

    public func flush() async throws {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        try await performFlush()
    }

    private func performFlush() async throws {
        try await replayQueuedBatches()
        try await drainPending(fullBatchesOnly: false)
    }

    private func drainPending(fullBatchesOnly: Bool) async throws {
        while !pending.isEmpty {
            if fullBatchesOnly, pending.count < policy.maxBatchSize {
                break
            }

            let count = min(policy.maxBatchSize, pending.count)
            let batch = Array(pending.prefix(count))
            pending.removeFirst(count)

            do {
                try await sendWithRetry(batch)
            } catch {
                // Queueing a batch the server will never accept only delays
                // the batches behind it, so permanent failures are dropped.
                guard error.isRetryableFailure else { continue }
                try await queue.enqueue(batch)
                try await queue.trim(to: policy.maxQueuedBatches)
            }
        }

        if !pending.isEmpty {
            scheduleFlushIfNeeded()
        }
    }

    private func replayQueuedBatches() async throws {
        while let batch = try await queue.oldest() {
            do {
                try await sendWithRetry(batch.events)
                try await queue.remove(id: batch.id)
            } catch {
                // A permanent rejection would otherwise block every batch
                // behind it forever, so drop it and keep the queue moving.
                if !error.isRetryableFailure {
                    try await queue.remove(id: batch.id)
                    continue
                }
                return
            }
        }
    }

    private func sendWithRetry(_ events: [LogEvent]) async throws {
        var delay = policy.retry.initialDelay

        for attempt in 1...policy.retry.maximumAttempts {
            do {
                try await transport.send(events)
                return
            } catch {
                guard error.isRetryableFailure else { throw error }
                guard attempt < policy.retry.maximumAttempts else { throw error }
                if delay > 0 {
                    let nanoseconds = UInt64(min(delay, 86_400) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                }
                delay = min(max(delay * 2, policy.retry.initialDelay), policy.retry.maximumDelay)
            }
        }
    }

    private func scheduleFlushIfNeeded() {
        guard scheduledFlush == nil, !pending.isEmpty else { return }
        let nanoseconds = UInt64(min(policy.flushInterval, 86_400) * 1_000_000_000)

        scheduledFlush = Task { [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.flushFromTimer()
        }
    }

    private func flushFromTimer() async {
        scheduledFlush = nil
        try? await performFlush()
    }
}
