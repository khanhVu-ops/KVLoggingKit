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

/// A destination that takes each event on the thread that logged it, instead of
/// in a batch a moment later.
///
/// Meant for sinks that are thread-safe and cheap per call, where a delay costs
/// something: the unified log, whose entries otherwise arrive about one batch
/// interval late, on another thread, and can be lost if the process dies before
/// the batch is written. Anything that does I/O belongs in the batch.
///
/// `LogClient` writes to it immediately only when every configured processor is
/// a ``SynchronousLogProcessor`` — an event must never skip redaction to get
/// there faster. With an async-only processor in the chain it is batched like
/// any other destination and receives ``LogDestination/write(_:)`` instead.
public protocol ImmediateLogDestination: LogDestination {
    /// `false` opts this instance back into batching.
    var writesImmediately: Bool { get }
    /// Called on the logging thread, after the processor chain has run.
    func writeImmediately(_ event: LogEvent)
}

/// A processor that needs no suspension, so `LogClient` can run it on the
/// calling thread for an ``ImmediateLogDestination``.
///
/// Conforming supplies ``LogProcessor/process(_:)`` as well. The built-in
/// processors conform; a custom one that only implements `process(_:)` keeps
/// working but makes immediate destinations fall back to batching.
public protocol SynchronousLogProcessor: LogProcessor {
    func processSynchronously(_ event: LogEvent) -> LogEvent?
}

public extension SynchronousLogProcessor {
    func process(_ event: LogEvent) async -> LogEvent? {
        processSynchronously(event)
    }
}
