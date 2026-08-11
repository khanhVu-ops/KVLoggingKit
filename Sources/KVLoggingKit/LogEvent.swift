import Foundation

public struct LogSource: Codable, Equatable, Sendable {
    public let file: String
    public let function: String
    public let line: UInt

    public init(file: String, function: String, line: UInt) {
        self.file = file
        self.function = function
        self.line = line
    }
}

public struct LogError: Codable, Equatable, Sendable {
    public let type: String
    public let message: String

    public init(_ error: any Error) {
        type = String(reflecting: Swift.type(of: error))
        message = String(describing: error)
    }
}

public struct LogEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let message: String
    public let category: String?
    public let metadata: LogMetadata
    public let error: LogError?
    public let source: LogSource

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        message: String,
        category: String? = nil,
        metadata: LogMetadata = [:],
        error: (any Error)? = nil,
        source: LogSource = .init(file: "unknown", function: "unknown", line: 0)
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.category = category
        self.metadata = metadata
        self.error = error.map(LogError.init)
        self.source = source
    }

    internal init(
        id: UUID,
        timestamp: Date,
        level: LogLevel,
        message: String,
        category: String?,
        metadata: LogMetadata,
        error: LogError?,
        source: LogSource
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.category = category
        self.metadata = metadata
        self.error = error
        self.source = source
    }

    public func redactedForRemote() -> Self {
        let sanitizedMetadata = metadata.mapValues { field in
            guard field.privacy == .private else { return field }
            return LogField(value: .string("<redacted>"), privacy: .private)
        }

        return .init(
            id: id,
            timestamp: timestamp,
            level: level,
            message: message,
            category: category,
            metadata: sanitizedMetadata,
            error: error,
            source: source
        )
    }

    internal func replacing(
        message: String? = nil,
        metadata: LogMetadata? = nil
    ) -> Self {
        .init(
            id: id,
            timestamp: timestamp,
            level: level,
            message: message ?? self.message,
            category: category,
            metadata: metadata ?? self.metadata,
            error: error,
            source: source
        )
    }
}
