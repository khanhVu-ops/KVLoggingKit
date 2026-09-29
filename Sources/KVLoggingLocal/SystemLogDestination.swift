import Foundation
import KVLoggingKit
import OSLog

/// Writes to the unified log.
///
/// Fields declared `.private` are passed to `os_log` as private data, so they
/// are elided from Console.app and from sysdiagnose archives on release builds.
/// Without that, marking a field private would only protect it on the way to a
/// remote destination while leaving it in the clear on the device.
///
/// By default each event is written on the thread that logged it, before the
/// log call returns — see ``Mode``. `os_log` is thread-safe and does no I/O on
/// the caller's thread, so there is nothing to gain from batching it.
public actor SystemLogDestination: ImmediateLogDestination {
    public enum Mode: Sendable {
        /// Written on the calling thread as soon as the processor chain has run.
        /// Entries appear in the Xcode console in real time and on the right
        /// thread, and an entry written before a crash is not lost with the
        /// batch it was waiting in.
        ///
        /// Requires every `LogConfiguration.processors` entry to be a
        /// `SynchronousLogProcessor`, as the built-in ones are; otherwise the
        /// destination is batched as if it were `.batched`.
        case immediate
        /// Written with every other destination, one batch at a time, on the
        /// log worker — the behaviour before 1.2.0.
        case batched
    }

    public nonisolated let mode: Mode

    private let subsystem: String
    private let defaultCategory: String
    private let logs = LogCache()

    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "KVLoggingKit",
        category: String = "application",
        mode: Mode = .immediate
    ) {
        self.subsystem = subsystem
        self.defaultCategory = category
        self.mode = mode
    }

    public nonisolated var writesImmediately: Bool {
        mode == .immediate
    }

    public nonisolated func writeImmediately(_ event: LogEvent) {
        emit(event)
    }

    public func write(_ events: [LogEvent]) async throws {
        for event in events {
            emit(event)
        }
    }

    private nonisolated func emit(_ event: LogEvent) {
        let (publicText, privateText) = render(event)

        os_log(
            "%{public}@%{private}@",
            log: logs.log(subsystem: subsystem, category: event.category ?? defaultCategory),
            type: event.level.osLogType,
            publicText,
            privateText
        )
    }

    /// Splits the rendered line so the private half can be handed to `os_log`
    /// separately.
    private nonisolated func render(_ event: LogEvent) -> (public: String, private: String) {
        var publicFields: [String] = []
        var privateFields: [String] = []

        for (key, field) in event.metadata.sorted(by: { $0.key < $1.key }) {
            let rendered = "\(key)=\(field.value.stringValue)"
            switch field.privacy {
            case .public: publicFields.append(rendered)
            case .private: privateFields.append(rendered)
            }
        }

        var publicText = event.message
        if !publicFields.isEmpty {
            publicText += " " + publicFields.joined(separator: " ")
        }
        if let error = event.error {
            publicText += " error=\(error.type)"
            if let code = error.code {
                publicText += "(\(code))"
            }
        }

        var privateText = privateFields.isEmpty
            ? ""
            : " " + privateFields.joined(separator: " ")

        // A description can embed a failing URL or payload, so it belongs on
        // the private side even though the type and code do not.
        if let error = event.error, !error.message.isEmpty {
            privateText += " error_message=\(error.message)"
        }

        return (publicText, privateText)
    }
}

/// One `OSLog` per category, shared by every thread that writes.
///
/// Locked rather than actor-isolated because immediate writes run on the
/// caller's thread and must not hop.
private final class LogCache: @unchecked Sendable {
    private let lock = NSLock()
    private var logs: [String: OSLog] = [:]

    func log(subsystem: String, category: String) -> OSLog {
        lock.lock()
        defer { lock.unlock() }

        if let existing = logs[category] { return existing }
        let log = OSLog(subsystem: subsystem, category: category)
        logs[category] = log
        return log
    }
}

private extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .trace, .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .default
        case .error: .error
        case .critical: .fault
        }
    }
}
