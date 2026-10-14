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

    /// Status code with its reason phrase, e.g. "404 Not Found".
    static func statusDescription(for record: NetworkLogRecord) -> String {
        if record.state == .pending {
            guard let statusCode = record.statusCode else { return "Pending" }
            return "\(statusCode) · \(record.isEventStream ? "Streaming" : "Receiving")"
        }
        guard let statusCode = record.statusCode else { return "Failed" }
        let reason = reasonPhrases[statusCode]
            ?? HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
        return "\(statusCode) \(reason)"
    }

    /// Foundation's phrases are odd for common codes ("200 No Error"), so the
    /// RFC wording wins where it matters.
    private static let reasonPhrases: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
        301: "Moved Permanently", 302: "Found", 304: "Not Modified",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        409: "Conflict", 422: "Unprocessable Content", 429: "Too Many Requests",
        500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable",
        504: "Gateway Timeout"
    ]

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

    static func isFailure(_ record: NetworkLogRecord) -> Bool {
        record.error != nil || (record.statusCode.map { $0 >= 400 } ?? false)
    }

    static func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": .blue
        case "POST": .green
        case "PUT", "PATCH": .orange
        case "DELETE": .red
        default: .purple
        }
    }

    static func duration(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        if value < 0.001 { return "< 1 ms" }
        if value < 1 { return "\(Int(value * 1_000)) ms" }
        return String(format: "%.2f s", value)
    }

    static func byteCount(_ value: Int) -> String {
        guard value > 0 else { return "0 bytes" }
        return byteFormatter.string(fromByteCount: Int64(value))
    }

    /// Size of the response payload, preferring what went over the wire.
    static func responseSize(for record: NetworkLogRecord) -> String? {
        if let received = record.metrics?.responseBytesReceived, received > 0 {
            return byteCount(Int(received))
        }
        guard let body = record.response?.body, body.byteCount > 0 else { return nil }
        return byteCount(body.byteCount)
    }

    static func eventCount(_ count: Int) -> String {
        count == 1 ? "1 event" : "\(count) events"
    }

    /// "+1.234s" from the start of the request.
    static func offset(_ value: TimeInterval) -> String {
        String(format: "+%.3fs", value)
    }

    /// A stable color per event type, so the same type reads the same everywhere.
    static func eventColor(_ type: String?) -> Color {
        guard let type = type?.lowercased() else { return .secondary }
        if type.contains("error") || type.contains("fail") { return .red }
        if type == "done" || type.contains("end") || type.contains("stop") || type.contains("complete") { return .green }
        let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo, .brown, .cyan]
        let hash = type.unicodeScalars.reduce(5_381) { ($0 &* 33) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    /// Pretty-printed JSON when the payload is JSON, otherwise unchanged.
    static func prettyEventData(_ data: String) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(data.utf8), options: [.fragmentsAllowed]),
            object is [String: Any] || object is [Any],
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else { return data }
        return String(decoding: pretty, as: UTF8.self)
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func shortTime(_ date: Date) -> String {
        shortTimeFormatter.string(from: date)
    }

    static func queryItems(for record: NetworkLogRecord) -> [URLQueryItem] {
        URLComponents(string: record.request.url)?.queryItems ?? []
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

    /// "application/json · 41 B · truncated"
    static func bodyMeta(_ body: NetworkLogBody) -> String? {
        var parts: [String] = []
        if let contentType = body.contentType?.split(separator: ";").first {
            parts.append(String(contentType).trimmingCharacters(in: .whitespaces))
        }
        if body.byteCount > 0 { parts.append(byteCount(body.byteCount)) }
        if body.isTruncated { parts.append("truncated") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
