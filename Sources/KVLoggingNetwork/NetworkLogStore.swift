import Foundation
import KVLoggingKit

/// Bounded, in-memory ring of captured exchanges backing the on-device viewer.
///
/// Records never touch disk here. Long-term retention is the job of the normal
/// `LogClient` destinations, which only receive the redacted summary event.
public actor NetworkLogStore {
    public static let shared = NetworkLogStore()

    private var buffer: LogRingBuffer<NetworkLogRecord>
    /// Index into the ring for records still in flight, so completing one does
    /// not require scanning the whole buffer.
    private var pendingIDs: Set<UUID> = []
    private let broadcaster = ChangeBroadcaster()

    public init(limit: Int = 250) {
        self.buffer = LogRingBuffer(capacity: limit)
    }

    /// Newest first.
    public func all() -> [NetworkLogRecord] {
        buffer.newestFirst()
    }

    public func count() -> Int {
        buffer.count
    }

    public func record(id: UUID) -> NetworkLogRecord? {
        buffer.newestFirst().first { $0.id == id }
    }

    public func insert(_ record: NetworkLogRecord) {
        buffer.append(record)
        if record.state == .pending {
            pendingIDs.insert(record.id)
        }
        broadcaster.send()
    }

    /// Replaces a record in place, or inserts it if the ring already evicted it.
    public func update(_ record: NetworkLogRecord) {
        pendingIDs.remove(record.id)

        guard buffer.replace(where: { $0.id == record.id }, with: record) else {
            insert(record)
            return
        }
        broadcaster.send()
    }

    public func clear() {
        buffer.removeAll()
        pendingIDs.removeAll()
        broadcaster.send()
    }

    /// Fires once immediately, then on every change. Call ``all()`` to read.
    public nonisolated func changes() -> AsyncStream<Void> {
        broadcaster.observe()
    }
}
