public struct ScopedLogClient: Sendable {
    private let client: LogClient
    private let category: String?
    private let metadata: LogMetadata

    init(client: LogClient, category: String?, metadata: LogMetadata) {
        self.client = client
        self.category = category
        self.metadata = metadata
    }

    public func log(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        metadata eventMetadata: LogMetadata = [:],
        error: (any Error)? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        client.log(
            level,
            message(),
            category: category,
            metadata: metadata.merging(eventMetadata) { _, eventValue in eventValue },
            error: error,
            file: file,
            function: function,
            line: line
        )
    }

    public func trace(
        _ message: @autoclosure () -> String,
        metadata: LogMetadata = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.trace, message(), metadata: metadata, file: file, function: function, line: line)
    }

    public func debug(
        _ message: @autoclosure () -> String,
        metadata: LogMetadata = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.debug, message(), metadata: metadata, file: file, function: function, line: line)
    }

    public func info(
        _ message: @autoclosure () -> String,
        metadata: LogMetadata = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.info, message(), metadata: metadata, file: file, function: function, line: line)
    }

    public func notice(
        _ message: @autoclosure () -> String,
        metadata: LogMetadata = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.notice, message(), metadata: metadata, file: file, function: function, line: line)
    }

    public func warning(
        _ message: @autoclosure () -> String,
        metadata: LogMetadata = [:],
        error: (any Error)? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.warning, message(), metadata: metadata, error: error, file: file, function: function, line: line)
    }

    public func error(
        _ message: @autoclosure () -> String,
        metadata: LogMetadata = [:],
        error: (any Error)? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.error, message(), metadata: metadata, error: error, file: file, function: function, line: line)
    }

    public func critical(
        _ message: @autoclosure () -> String,
        metadata: LogMetadata = [:],
        error: (any Error)? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        log(.critical, message(), metadata: metadata, error: error, file: file, function: function, line: line)
    }
}
