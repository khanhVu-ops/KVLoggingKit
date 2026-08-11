import Foundation
import KVLoggingKit
import OSLog

public actor SystemLogDestination: LogDestination {
    private let subsystem: String
    private let defaultCategory: String

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
        let category = event.category ?? defaultCategory
        let rendered = render(event)

        if #available(iOS 14.0, macOS 11.0, *) {
            let logger = Logger(subsystem: subsystem, category: category)
            switch event.level {
            case .trace, .debug:
                logger.debug("\(rendered, privacy: .public)")
            case .info:
                logger.info("\(rendered, privacy: .public)")
            case .notice:
                logger.notice("\(rendered, privacy: .public)")
            case .warning:
                logger.warning("\(rendered, privacy: .public)")
            case .error:
                logger.error("\(rendered, privacy: .public)")
            case .critical:
                logger.fault("\(rendered, privacy: .public)")
            }
        } else {
            let log = OSLog(subsystem: subsystem, category: category)
            os_log("%{public}@", log: log, type: event.level.osLogType, rendered)
        }
    }

    private func render(_ event: LogEvent) -> String {
        let metadata = event.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.value.stringValue)" }
            .joined(separator: " ")
        let error = event.error.map { " error=\($0.type):\($0.message)" } ?? ""
        let suffix = metadata.isEmpty ? "" : " \(metadata)"
        return "\(event.message)\(suffix)\(error)"
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
