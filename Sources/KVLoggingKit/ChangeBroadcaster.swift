import Foundation

/// Fan-out of "something changed" signals, without shipping the data itself.
///
/// Observers pull a snapshot when they are ready. Because each stream buffers
/// only the newest signal, a burst of a thousand events collapses into a single
/// wake-up — the store never copies its contents once per event just in case
/// somebody is watching.
public struct ChangeBroadcaster: Sendable {
    /// Locked rather than actor-isolated: `onTermination` fires on whatever
    /// thread tears the stream down, so registration cannot rely on the
    /// isolation of whichever store owns the broadcaster.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [Int: AsyncStream<Void>.Continuation] = [:]
        private var nextToken = 0

        func add(_ continuation: AsyncStream<Void>.Continuation) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let token = nextToken
            nextToken += 1
            continuations[token] = continuation
            return token
        }

        func remove(_ token: Int) {
            lock.lock()
            continuations[token] = nil
            lock.unlock()
        }

        var isEmpty: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuations.isEmpty
        }

        func broadcast() {
            lock.lock()
            let targets = Array(continuations.values)
            lock.unlock()

            for continuation in targets {
                continuation.yield(())
            }
        }
    }

    private let registry = Registry()

    public init() {}

    public var hasObservers: Bool { !registry.isEmpty }

    /// Emits once immediately so a new observer renders without waiting for the
    /// next change.
    public func observe() -> AsyncStream<Void> {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = registry.add(stream.continuation)

        stream.continuation.onTermination = { [registry] _ in
            registry.remove(token)
        }
        stream.continuation.yield(())

        return stream.stream
    }

    public func send() {
        registry.broadcast()
    }
}
