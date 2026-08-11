import Foundation

public extension NetworkLogRecord {
    /// A `curl` invocation that reproduces the captured request.
    ///
    /// Redacted headers and query items keep their `<redacted>` placeholder, so
    /// the command is safe to paste into a bug report but needs the real
    /// credential filled in before it will run.
    var curlCommand: String {
        var lines = ["curl -X \(request.method) '\(Self.escaped(request.url))'"]

        for field in request.headers.keys.sorted() {
            guard let value = request.headers[field] else { continue }
            lines.append("  -H '\(Self.escaped(field)): \(Self.escaped(value))'")
        }

        switch request.body.content {
        case let .text(text):
            lines.append("  --data-binary '\(Self.escaped(text))'")
        case .binary:
            lines.append("  --data-binary '<\(request.body.byteCount) bytes of binary data>'")
        case let .notCaptured(reason):
            lines.append("  # body not captured: \(reason)")
        case .empty:
            break
        }

        if request.timeout > 0, request.timeout != 60 {
            lines.append("  --max-time \(Int(request.timeout))")
        }

        return lines.joined(separator: " \\\n")
    }

    /// Single-quoted shell strings only need `'` itself escaped.
    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: #"'\''"#)
    }
}
