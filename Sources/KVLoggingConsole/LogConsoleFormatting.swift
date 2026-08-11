import Foundation
import KVLoggingKit
import SwiftUI

@available(iOS 16.0, macOS 13.0, *)
@MainActor
enum LogConsoleFormatting {
    static func label(for level: LogLevel) -> String {
        switch level {
        case .trace: "TRACE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .warning: "WARN"
        case .error: "ERROR"
        case .critical: "CRIT"
        }
    }

    static func color(for level: LogLevel) -> Color {
        switch level {
        case .trace: .secondary
        case .debug: .teal
        case .info: .blue
        case .notice: .indigo
        case .warning: .orange
        case .error: .red
        case .critical: .purple
        }
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// One plain-text line, used by the share sheet and the clipboard.
    static func line(for event: LogEvent) -> String {
        var parts = [
            timestampFormatter.string(from: event.timestamp),
            "[\(label(for: event.level))]"
        ]
        if let category = event.category {
            parts.append("[\(category)]")
        }
        parts.append(event.message)

        if !event.metadata.isEmpty {
            let metadata = event.metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.value.stringValue)" }
                .joined(separator: " ")
            parts.append(metadata)
        }
        if let error = event.error {
            parts.append("error=\(error.type)(\(error.code.map(String.init) ?? "-")): \(error.message)")
        }
        parts.append("(\(event.source.file):\(event.source.line))")

        return parts.joined(separator: " ")
    }

    /// Timestamps are pinned to POSIX so a device on a non-Gregorian calendar
    /// still produces sortable, comparable output.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
