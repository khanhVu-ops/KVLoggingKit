public protocol LogDestination: Sendable {
    func write(_ events: [LogEvent]) async throws
    func flush() async throws
}

public extension LogDestination {
    func flush() async throws {}
}

public protocol LogProcessor: Sendable {
    func process(_ event: LogEvent) async -> LogEvent?
}
