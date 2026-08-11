import Foundation
import KVLoggingKit
import KVLoggingSecurity

public struct QueuedLogBatch: Codable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let events: [LogEvent]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        events: [LogEvent]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.events = events
    }
}

public protocol LogBatchQueue: Sendable {
    func enqueue(_ events: [LogEvent]) async throws
    func oldest() async throws -> QueuedLogBatch?
    func remove(id: UUID) async throws
    func count() async throws -> Int
    /// Discards the oldest entries until at most `limit` remain.
    func trim(to limit: Int) async throws
}

public actor MemoryLogBatchQueue: LogBatchQueue {
    private var batches: [QueuedLogBatch] = []

    public init() {}

    public func enqueue(_ events: [LogEvent]) async throws {
        batches.append(QueuedLogBatch(events: events))
    }

    public func oldest() async throws -> QueuedLogBatch? {
        batches.first
    }

    public func remove(id: UUID) async throws {
        batches.removeAll { $0.id == id }
    }

    public func count() async throws -> Int {
        batches.count
    }

    public func trim(to limit: Int) async throws {
        guard batches.count > limit else { return }
        batches.removeFirst(batches.count - limit)
    }
}

public actor DiskLogBatchQueue: LogBatchQueue {
    private let directory: URL
    private let cipher: any LogDataCipher
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directory: URL,
        cipher: any LogDataCipher = NoEncryptionCipher()
    ) throws {
        self.directory = directory
        self.cipher = cipher
        self.fileManager = .default
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    public func enqueue(_ events: [LogEvent]) async throws {
        let batch = QueuedLogBatch(events: events)
        let data = try cipher.seal(encoder.encode(batch))

        // Names sort lexicographically to give FIFO order. The millisecond
        // timestamp alone is not enough: several batches can land inside one
        // millisecond, and the UUID that used to break the tie is random, so
        // replay order was effectively arbitrary under load.
        let timestamp = String(format: "%020.0f", batch.createdAt.timeIntervalSince1970 * 1_000)
        let sequence = String(format: "%09d", nextSequenceNumber)
        nextSequenceNumber &+= 1

        let file = directory.appendingPathComponent(
            "\(timestamp)-\(sequence)-\(batch.id.uuidString).kvbatch"
        )
        try data.write(to: file, options: .atomic)
    }

    /// Skips and deletes entries that cannot be decrypted or decoded.
    ///
    /// A single truncated or key-rotated file used to throw here on every call,
    /// which stalled the replay loop permanently and left the whole queue
    /// undeliverable. One unreadable batch should cost one batch.
    public func oldest() async throws -> QueuedLogBatch? {
        for file in queueFiles() {
            do {
                return try decoder.decode(
                    QueuedLogBatch.self,
                    from: cipher.open(Data(contentsOf: file))
                )
            } catch {
                try? fileManager.removeItem(at: file)
                discardedBatchCount += 1
            }
        }
        return nil
    }

    public func remove(id: UUID) async throws {
        guard let file = queueFiles().first(where: {
            $0.lastPathComponent.contains(id.uuidString)
        }) else { return }
        try fileManager.removeItem(at: file)
    }

    public func count() async throws -> Int {
        queueFiles().count
    }

    public func trim(to limit: Int) async throws {
        let files = queueFiles()
        guard files.count > limit else { return }
        for file in files.prefix(files.count - limit) {
            try? fileManager.removeItem(at: file)
            discardedBatchCount += 1
        }
    }

    /// Batches dropped because they were unreadable or the queue was full.
    /// Surfacing this matters: silent loss looks identical to delivery.
    public private(set) var discardedBatchCount = 0

    private var nextSequenceNumber = 0

    private func queueFiles() -> [URL] {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "kvbatch" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
