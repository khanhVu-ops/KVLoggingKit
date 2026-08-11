import KVLoggingKit

public actor InMemoryLogDestination: LogDestination {
    private var events: [LogEvent]

    public init(events: [LogEvent] = []) {
        self.events = events
    }

    public func write(_ events: [LogEvent]) async throws {
        self.events.append(contentsOf: events)
    }

    public func snapshot() -> [LogEvent] {
        events
    }

    public func clear() {
        events.removeAll(keepingCapacity: true)
    }
}
