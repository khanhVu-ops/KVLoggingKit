import Foundation
import KVLoggingKit

/// Keeps the most recent events in memory so the console can show them.
///
/// This is an ordinary `LogDestination`, so it sees exactly what the other
/// destinations see, after the processor chain has run. Add it only when
/// ``DebugAccessPolicy`` allows the console — when it is absent the app pays
/// nothing at all.
public actor ConsoleLogStore: LogDestination {
    public static let shared = ConsoleLogStore()

    private var buffer: LogRingBuffer<LogEvent>
    private let broadcaster = ChangeBroadcaster()

    public init(limit: Int = 2_000) {
        self.buffer = LogRingBuffer(capacity: limit)
    }

    public func write(_ events: [LogEvent]) async throws {
        for event in events {
            buffer.append(event)
        }
        broadcaster.send()
    }

    /// Newest first.
    public func all() -> [LogEvent] {
        buffer.newestFirst()
    }

    public func count() -> Int {
        buffer.count
    }

    public func clear() {
        buffer.removeAll()
        broadcaster.send()
    }

    /// Fires once immediately, then on every change. Call ``all()`` to read.
    public nonisolated func changes() -> AsyncStream<Void> {
        broadcaster.observe()
    }
}
