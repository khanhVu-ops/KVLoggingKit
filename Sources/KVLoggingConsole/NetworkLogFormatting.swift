import Foundation
import KVLoggingNetwork
import SwiftUI

@available(iOS 16.0, macOS 13.0, *)
@MainActor
enum NetworkLogFormatting {
    static func statusText(for record: NetworkLogRecord) -> String {
        if record.state == .pending { return "…" }
        if let statusCode = record.statusCode { return String(statusCode) }
        return "ERR"
    }

    static func statusColor(for record: NetworkLogRecord) -> Color {
        switch record.state {
        case .pending:
            return .secondary
        case .succeeded:
            return .green
        case .failed:
            guard let statusCode = record.statusCode else { return .red }
            return statusCode >= 500 ? .red : .orange
        }
    }

    static func duration(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        if value < 1 { return "\(Int(value * 1_000)) ms" }
        return String(format: "%.2f s", value)
    }

    static func byteCount(_ value: Int) -> String {
        guard value > 0 else { return "0 B" }
        return byteFormatter.string(fromByteCount: Int64(value))
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func bodyText(_ body: NetworkLogBody) -> String {
        switch body.content {
        case .empty:
            return "(empty)"
        case let .text(text):
            return body.isTruncated
                ? text + "\n\n… truncated, \(byteCount(body.byteCount)) total"
                : text
        case .binary:
            return "(binary, \(byteCount(body.byteCount)))"
        case let .notCaptured(reason):
            return "(not captured: \(reason))"
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
