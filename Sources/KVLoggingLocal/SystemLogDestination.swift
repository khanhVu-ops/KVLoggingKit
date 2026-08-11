import Foundation
import KVLoggingKit
import OSLog

/// Writes to the unified log.
///
/// Fields declared `.private` are passed to `os_log` as private data, so they
/// are elided from Console.app and from sysdiagnose archives on release builds.
/// Without that, marking a field private would only protect it on the way to a
/// remote destination while leaving it in the clear on the device.
public actor SystemLogDestination: LogDestination {
    private let subsystem: String
    private let defaultCategory: String
    private var logs: [String: OSLog] = [:]

    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "KVLoggingKit",
        category: String = "application"
    ) {
        self.subsystem = subsystem
        self.defaultCategory = category
    }

    public func write(_ events: [LogEvent]) async throws {
        for event in events {
            write(event)
        }
    }

    private func write(_ event: LogEvent) {
        let (publicText, privateText) = render(event)

        os_log(
            "%{public}@%{private}@",
            log: log(for: event.category ?? defaultCategory),
            type: event.level.osLogType,
            publicText,
            privateText
        )
    }

    private func log(for category: String) -> OSLog {
        if let existing = logs[category] { return existing }
        let log = OSLog(subsystem: subsystem, category: category)
        logs[category] = log
        return log
    }

    /// Splits the rendered line so the private half can be handed to `os_log`
    /// separately.
    private func render(_ event: LogEvent) -> (public: String, private: String) {
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
