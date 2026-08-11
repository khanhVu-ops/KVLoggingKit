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
    /// `NSError` domain. Present for every error, since Swift errors bridge.
    public let domain: String?
    /// `NSError` code. `URLError`, `POSIXError`, and friends put the useful
    /// discriminator here.
    public let code: Int?

    public init(_ error: any Error) {
        let bridged = error as NSError
        let reflected = String(reflecting: Swift.type(of: error))

        // Errors that bridge to Cocoa report `NSError` as their dynamic type,
        // which says nothing. Fall back to the domain in that case.
        type = reflected == "NSError" ? bridged.domain : reflected
        message = String(describing: error)
        domain = bridged.domain
        code = bridged.code
    }

    private init(type: String, message: String, domain: String?, code: Int?) {
        self.type = type
        self.message = message
        self.domain = domain
        self.code = code
    }

    func redacted(scrubbing redaction: LogRedaction) -> Self {
        .init(
            type: type,
            message: redaction.redacting(message),
            domain: domain,
            code: code
        )
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

    /// Strips everything a remote destination must not receive.
    ///
    /// Private metadata becomes `<redacted>`. The message and the error
    /// description are scrubbed with `redaction`, because a caller that
    /// interpolates a private value into the message text would otherwise send
    /// it verbatim — declaring metadata private does nothing for the string it
    /// was also pasted into.
    public func redactedForRemote(
        scrubbing redaction: LogRedaction = .default
    ) -> Self {
        let sanitizedMetadata = metadata.mapValues { field in
            guard field.privacy == .private else { return field }
            return LogField(value: .string("<redacted>"), privacy: .private)
        }

        return .init(
            id: id,
            timestamp: timestamp,
            level: level,
            message: redaction.redacting(message),
            category: category,
            metadata: sanitizedMetadata,
            error: error.map { $0.redacted(scrubbing: redaction) },
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
