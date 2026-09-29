public struct StaticContextProcessor: SynchronousLogProcessor {
    private let metadata: LogMetadata

    public init(metadata: LogMetadata) {
        self.metadata = metadata
    }

    public func processSynchronously(_ event: LogEvent) -> LogEvent? {
        event.replacing(
            metadata: metadata.merging(event.metadata) { _, eventValue in eventValue }
        )
    }
}
