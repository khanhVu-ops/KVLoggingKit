import Foundation
import KVLoggingKit
import KVLoggingSecurity

public enum RollingFileProtection: Sendable {
    case none
    case encrypted(any LogDataCipher)
}

public struct RollingFilePolicy: Sendable {
    public var maxFileSize: Int
    public var maxFileCount: Int
    public var retentionDays: Int
    public var protection: RollingFileProtection

    public init(
        maxFileSize: Int = 2_000_000,
        maxFileCount: Int = 5,
        retentionDays: Int = 7,
        protection: RollingFileProtection = .none
    ) {
        self.maxFileSize = max(1, maxFileSize)
        self.maxFileCount = max(1, maxFileCount)
        self.retentionDays = max(1, retentionDays)
        self.protection = protection
    }
}

public actor RollingFileDestination: LogDestination {
    private let directory: URL
    private let policy: RollingFilePolicy
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private var handle: FileHandle?
    private var currentByteCount: Int?
    private var needsPrune = true

    deinit {
        try? handle?.synchronize()
        try? handle?.close()
    }

    public init(
        directory: URL,
        policy: RollingFilePolicy = .init()
    ) throws {
        self.directory = directory
        self.policy = policy
        self.fileManager = .default
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Writes the batch with one `write` syscall per rotation segment.
    ///
    /// The previous version opened, seeked, wrote, fsynced, and closed a
    /// `FileHandle` for every single event, then listed the directory twice to
    /// prune. That is roughly five syscalls per log line; now the handle is
    /// held open, the batch is coalesced into one buffer, and pruning only runs
    /// after a rotation actually happens.
    public func write(_ events: [LogEvent]) async throws {
        var buffer = Data()

        for event in events {
            let record = try encodedRecord(for: event)

            if try wouldRotate(forAdditionalBytes: buffer.count + record.count) {
                try append(buffer)
                buffer.removeAll(keepingCapacity: true)
                try rotate()
            }
            buffer.append(record)
        }

        try append(buffer)

        if needsPrune {
            needsPrune = false
            try pruneFiles()
        }
    }

    public func flush() async throws {
        try handle?.synchronize()
    }

    public func logFiles() -> [URL] {
        retainedFiles().sorted { lhs, rhs in
            modificationDate(for: lhs) > modificationDate(for: rhs)
        }
    }

    /// Copies retained files, flushing the open handle first so the export is
    /// not missing the most recent lines.
    @discardableResult
    public func export(to exportDirectory: URL) throws -> URL {
        try? handle?.synchronize()

        try fileManager.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )

        for source in logFiles() {
            let destination = exportDirectory.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
        return exportDirectory
    }

    private var currentFileURL: URL {
        directory.appendingPathComponent("current.kvlog")
    }

    private func encodedRecord(for event: LogEvent) throws -> Data {
        let eventData = try encoder.encode(event)
        let payload: Data

        switch policy.protection {
        case .none:
            payload = eventData
        case let .encrypted(cipher):
            payload = Data(try cipher.seal(eventData).base64EncodedString().utf8)
        }

        var record = payload
        record.append(0x0A)
        return record
    }

    private func wouldRotate(forAdditionalBytes additionalBytes: Int) throws -> Bool {
        let size = try currentSize()
        return size > 0 && size + additionalBytes > policy.maxFileSize
    }

    private func rotate() throws {
        try closeHandle()

        let rotatedName = "log-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString).kvlog"
        try fileManager.moveItem(
            at: currentFileURL,
            to: directory.appendingPathComponent(rotatedName)
        )
        currentByteCount = 0
        needsPrune = true
    }

    private func append(_ data: Data) throws {
        guard !data.isEmpty else { return }

        let handle = try openHandle()
        let sizeBeforeWrite = try currentSize()

        if #available(iOS 13.4, macOS 10.15.4, *) {
            try handle.write(contentsOf: data)
        } else {
            handle.write(data)
        }

        currentByteCount = sizeBeforeWrite + data.count
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }

        if !fileManager.fileExists(atPath: currentFileURL.path) {
            fileManager.createFile(atPath: currentFileURL.path, contents: nil)
            currentByteCount = 0
        }

        let handle = try FileHandle(forWritingTo: currentFileURL)
        if #available(iOS 13.4, macOS 10.15.4, *) {
            try handle.seekToEnd()
        } else {
            handle.seekToEndOfFile()
        }
        self.handle = handle
        return handle
    }

    private func closeHandle() throws {
        guard let handle else { return }
        try? handle.synchronize()
        try? handle.close()
        self.handle = nil
    }

    /// Cached so the size check does not stat the file on every batch.
    private func currentSize() throws -> Int {
        if let currentByteCount { return currentByteCount }

        let attributes = try? fileManager.attributesOfItem(atPath: currentFileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        currentByteCount = size
        return size
    }

    private func pruneFiles() throws {
        let expirationDate = Calendar.current.date(
            byAdding: .day,
            value: -policy.retentionDays,
            to: Date()
        ) ?? .distantPast

        for file in rotatedFiles() where modificationDate(for: file) < expirationDate {
            try? fileManager.removeItem(at: file)
        }

        let filesByNewest = rotatedFiles().sorted {
            modificationDate(for: $0) > modificationDate(for: $1)
        }
        // The open file counts toward the cap even though it is never pruned.
        for file in filesByNewest.dropFirst(max(0, policy.maxFileCount - 1)) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func retainedFiles() -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { $0.pathExtension == "kvlog" }
    }

    /// Everything except the file currently open for writing. Pruning must
    /// never delete it out from under the live handle.
    private func rotatedFiles() -> [URL] {
        retainedFiles().filter { $0.lastPathComponent != currentFileURL.lastPathComponent }
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
