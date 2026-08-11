public struct LogConfiguration: Sendable {
    public var minimumLevel: LogLevel
    public var processors: [any LogProcessor]
    public var internalErrorHandler: (@Sendable (any Error) -> Void)?

    public init(
        minimumLevel: LogLevel = .trace,
        processors: [any LogProcessor] = [],
        internalErrorHandler: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.minimumLevel = minimumLevel
        self.processors = processors
        self.internalErrorHandler = internalErrorHandler
    }

    public static let production = LogConfiguration(minimumLevel: .info)
}
