public struct StaticContextProcessor: LogProcessor {
    private let metadata: LogMetadata

    public init(metadata: LogMetadata) {
        self.metadata = metadata
    }

    public func process(_ event: LogEvent) async -> LogEvent? {
        event.replacing(
            metadata: metadata.merging(event.metadata) { _, eventValue in eventValue }
        )
    }
}
