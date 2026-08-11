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

    public func write(_ events: [LogEvent]) async throws {
        for event in events {
            let record = try encodedRecord(for: event)
            try rotateIfNeeded(forAdditionalBytes: record.count)
            try append(record, to: currentFileURL)
        }
        try pruneFiles()
    }

    public func flush() async throws {}

    public func logFiles() -> [URL] {
        retainedFiles().sorted { lhs, rhs in
            modificationDate(for: lhs) > modificationDate(for: rhs)
        }
    }

    @discardableResult
    public func export(to exportDirectory: URL) throws -> URL {
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

    private func rotateIfNeeded(forAdditionalBytes additionalBytes: Int) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: currentFileURL.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize > 0, currentSize + additionalBytes > policy.maxFileSize else {
            return
        }

        let rotatedName = "log-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString).kvlog"
        let rotatedURL = directory.appendingPathComponent(rotatedName)
        try fileManager.moveItem(at: currentFileURL, to: rotatedURL)
    }

    private func append(_ data: Data, to fileURL: URL) throws {
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        if #available(iOS 13.4, *) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } else {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.synchronizeFile()
        }
    }

    private func pruneFiles() throws {
        let expirationDate = Calendar.current.date(
            byAdding: .day,
            value: -policy.retentionDays,
            to: Date()
        ) ?? .distantPast

        for file in retainedFiles() where modificationDate(for: file) < expirationDate {
            try? fileManager.removeItem(at: file)
        }

        let filesByNewest = retainedFiles().sorted {
            modificationDate(for: $0) > modificationDate(for: $1)
        }
        for file in filesByNewest.dropFirst(policy.maxFileCount) {
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

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
