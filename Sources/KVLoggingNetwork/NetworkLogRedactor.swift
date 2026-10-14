import Foundation

/// Decides what a captured exchange is allowed to keep.
///
/// Defaults deny the header and body keys that usually carry credentials, cap
/// body size, and pretty-print JSON so the viewer stays readable.
public struct NetworkLogRedactor: Sendable {
    public static let placeholder = "<redacted>"
    /// Angle brackets percent-encode into `%3C…%3E`, which is unreadable in a
    /// URL, so query items get a plain-text marker instead.
    public static let queryPlaceholder = "REDACTED"

    /// Compared case-insensitively.
    public var redactedHeaderFields: Set<String>
    /// Compared case-insensitively against URL query item names.
    public var redactedQueryItems: Set<String>
    /// Compared case-insensitively against JSON object keys, at any depth.
    public var redactedBodyKeys: Set<String>
    public var maximumBodyByteCount: Int
    public var capturesRequestBodies: Bool
    public var capturesResponseBodies: Bool
    /// Strings in a server-sent event longer than this are replaced by a size
    /// marker. Streams often carry base64 audio or images per event, which is
    /// unreadable in the viewer and would dominate memory.
    public var maximumStreamStringLength: Int
    /// Non-JSON event data past this many bytes is cut.
    public var maximumStreamEventByteCount: Int

    public init(
        redactedHeaderFields: Set<String> = [
            "authorization",
            "proxy-authorization",
            "cookie",
            "set-cookie",
            "x-api-key",
            "x-auth-token",
            "x-access-token"
        ],
        redactedQueryItems: Set<String> = [
            "token",
            "access_token",
            "refresh_token",
            "api_key",
            "apikey",
            "password",
            "signature"
        ],
        redactedBodyKeys: Set<String> = [
            "password",
            "new_password",
            "old_password",
            "token",
            "access_token",
            "refresh_token",
            "id_token",
            "secret",
            "client_secret",
            "authorization",
            "pin",
            "otp",
            "card_number",
            "cvv"
        ],
        maximumBodyByteCount: Int = 32_768,
        capturesRequestBodies: Bool = true,
        capturesResponseBodies: Bool = true,
        maximumStreamStringLength: Int = 1_024,
        maximumStreamEventByteCount: Int = 16_384
    ) {
        self.redactedHeaderFields = Set(redactedHeaderFields.map { $0.lowercased() })
        self.redactedQueryItems = Set(redactedQueryItems.map { $0.lowercased() })
        self.redactedBodyKeys = Set(redactedBodyKeys.map { $0.lowercased() })
        self.maximumBodyByteCount = max(0, maximumBodyByteCount)
        self.capturesRequestBodies = capturesRequestBodies
        self.capturesResponseBodies = capturesResponseBodies
        self.maximumStreamStringLength = max(16, maximumStreamStringLength)
        self.maximumStreamEventByteCount = max(0, maximumStreamEventByteCount)
    }

    public static let `default` = NetworkLogRedactor()

    /// Keeps timing and status only. Suitable for builds shipped to users.
    public static let headersAndBodiesOff = NetworkLogRedactor(
        maximumBodyByteCount: 0,
        capturesRequestBodies: false,
        capturesResponseBodies: false
    )

    // MARK: - Headers

    public func redacted(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, entry in
            result[entry.key] = redactedHeaderFields.contains(entry.key.lowercased())
                ? Self.placeholder
                : entry.value
        }
    }

    // MARK: - URL

    public func redactedURLString(_ url: URL?) -> String {
        guard let url else { return "<invalid-url>" }
        guard
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems,
            !items.isEmpty
        else {
            return url.absoluteString
        }

        components.queryItems = items.map { item in
            guard redactedQueryItems.contains(item.name.lowercased()) else { return item }
            return URLQueryItem(name: item.name, value: Self.queryPlaceholder)
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    // MARK: - Bodies

    public func requestBody(
        from data: Data?,
        contentType: String?,
        hasUncapturableStream: Bool = false
    ) -> NetworkLogBody {
        guard capturesRequestBodies else {
            return .init(content: .notCaptured(reason: "Request body capture is off"))
        }
        if data == nil, hasUncapturableStream {
            return .init(content: .notCaptured(reason: "Body was supplied as an httpBodyStream"))
        }
        return body(from: data, contentType: contentType)
    }

    public func responseBody(from data: Data?, contentType: String?) -> NetworkLogBody {
        guard capturesResponseBodies else {
            return .init(content: .notCaptured(reason: "Response body capture is off"))
        }
        return body(from: data, contentType: contentType)
    }

    private func body(from data: Data?, contentType: String?) -> NetworkLogBody {
        guard let data, !data.isEmpty else {
            return .init(content: .empty, contentType: contentType)
        }

        let byteCount = data.count
        let isTruncated = byteCount > maximumBodyByteCount
        let capped = isTruncated ? data.prefix(maximumBodyByteCount) : data.prefix(byteCount)

        if maximumBodyByteCount == 0 {
            return .init(
                content: .notCaptured(reason: "Body exceeds the capture limit"),
                byteCount: byteCount,
                isTruncated: true,
                contentType: contentType
            )
        }

        if let json = redactedJSONText(from: Data(capped)), !isTruncated {
            return .init(
                content: .text(json),
                byteCount: byteCount,
                isTruncated: false,
                contentType: contentType
            )
        }

        guard let text = String(data: Data(capped), encoding: .utf8), isTextual(text, contentType: contentType) else {
            return .init(
                content: .binary,
                byteCount: byteCount,
                isTruncated: isTruncated,
                contentType: contentType
            )
        }

        return .init(
            content: .text(text),
            byteCount: byteCount,
            isTruncated: isTruncated,
            contentType: contentType
        )
    }

    // MARK: - Server-sent events

    /// Redacts one event: JSON keys as for bodies, long strings elided, and any
    /// streamed answer text pulled out for the viewer to join.
    func streamEvent(
        from fields: ServerSentEventFields,
        id: Int,
        offset: TimeInterval
    ) -> NetworkStreamEvent {
        let byteCount = fields.data.utf8.count
        var event = NetworkStreamEvent(
            id: id,
            offset: offset,
            event: fields.event,
            lastEventID: fields.id,
            type: fields.event,
            data: "",
            byteCount: byteCount
        )

        guard capturesResponseBodies else {
            event.data = "(not captured: Response body capture is off)"
            return event
        }

        if let object = try? JSONSerialization.jsonObject(
            with: Data(fields.data.utf8),
            options: [.fragmentsAllowed]
        ) {
            var elided = false
            let redacted = eliding(redactingJSONKeys(in: object), didElide: &elided)
            if event.type == nil, let type = (redacted as? [String: Any])?["type"] as? String {
                event.type = type
            }
            event.text = Self.streamedText(in: redacted, type: event.type, original: object)
            if let output = try? JSONSerialization.data(
                withJSONObject: redacted,
                options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
            ) {
                event.data = String(decoding: output, as: UTF8.self)
                event.isTruncated = elided
                return event
            }
        }

        if byteCount > maximumStreamEventByteCount {
            event.data = String(decoding: Data(fields.data.utf8).prefix(maximumStreamEventByteCount), as: UTF8.self)
            event.isTruncated = true
        } else {
            event.data = fields.data
        }
        return event
    }

    private func eliding(_ object: Any, didElide: inout Bool) -> Any {
        switch object {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { eliding($0, didElide: &didElide) }
        case let array as [Any]:
            return array.map { eliding($0, didElide: &didElide) }
        case let string as String where string.utf8.count > maximumStreamStringLength:
            didElide = true
            let size = ByteCountFormatter.string(fromByteCount: Int64(string.utf8.count), countStyle: .binary)
            return "<\(size) elided>"
        default:
            return object
        }
    }

    /// Text deltas from the shapes chat APIs commonly stream: a top-level
    /// `content`/`delta`/`text` string, OpenAI's `choices[0].delta.content`, and
    /// Anthropic's `delta.text`. Events typed as something other than a text
    /// delta (`activity`, `audio_chunk`, …) contribute nothing.
    static func streamedText(in redacted: Any, type: String?, original: Any) -> String? {
        if let type = type?.lowercased() {
            let isTextual = ["chunk", "delta", "token", "text", "message"].contains { type.contains($0) }
            let isMedia = ["audio", "image", "video"].contains { type.contains($0) }
            guard isTextual, !isMedia else { return nil }
        }

        // Read from the redacted object so a redacted key never leaks through,
        // but from the original for the value, which elision may have replaced.
        guard let object = redacted as? [String: Any], let source = original as? [String: Any] else {
            return nil
        }

        for key in ["content", "delta", "text"] where (object[key] as? String).map({ $0 != placeholder }) ?? false {
            if let value = source[key] as? String, !value.isEmpty { return value }
        }
        if let choices = source["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            return content
        }
        if let delta = source["delta"] as? [String: Any], let text = delta["text"] as? String {
            return text
        }
        return nil
    }

    private func isTextual(_ text: String, contentType: String?) -> Bool {
        if let contentType = contentType?.lowercased() {
            let textualMarkers = ["json", "text/", "xml", "javascript", "x-www-form-urlencoded", "graphql"]
            if textualMarkers.contains(where: contentType.contains) { return true }
            if contentType.hasPrefix("image/") || contentType.hasPrefix("video/") || contentType.hasPrefix("audio/") {
                return false
            }
        }
        // No usable content type: treat it as text only when it decoded without
        // control characters, which rules out most binary payloads.
        return !text.unicodeScalars.contains { scalar in
            scalar.value < 0x09 || (scalar.value > 0x0D && scalar.value < 0x20)
        }
    }

    /// Returns pretty-printed JSON with redacted keys, or `nil` when the data is not JSON.
    private func redactedJSONText(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        else { return nil }

        let redacted = redactingJSONKeys(in: object)
        guard
            let output = try? JSONSerialization.data(
                withJSONObject: redacted,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
            )
        else { return nil }

        return String(data: output, encoding: .utf8)
    }

    private func redactingJSONKeys(in object: Any) -> Any {
        switch object {
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = redactedBodyKeys.contains(entry.key.lowercased())
                    ? Self.placeholder
                    : redactingJSONKeys(in: entry.value)
            }
        case let array as [Any]:
            return array.map(redactingJSONKeys(in:))
        default:
            return object
        }
    }
}
