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
        let timestamp = String(format: "%020.0f", batch.createdAt.timeIntervalSince1970 * 1_000)
        let file = directory.appendingPathComponent("\(timestamp)-\(batch.id.uuidString).kvbatch")
        try data.write(to: file, options: .atomic)
    }

    public func oldest() async throws -> QueuedLogBatch? {
        guard let file = queueFiles().first else { return nil }
        return try decoder.decode(
            QueuedLogBatch.self,
            from: cipher.open(Data(contentsOf: file))
        )
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
