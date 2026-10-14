import Foundation

/// One server-sent event, already redacted.
public struct NetworkStreamEvent: Codable, Equatable, Identifiable, Sendable {
    /// Position in the stream, starting at 0. Stays stable when older events
    /// are dropped, so it doubles as the identity.
    public var id: Int
    /// Seconds from the start of the request to the chunk that completed this event.
    public var offset: TimeInterval
    /// The SSE `event:` field.
    public var event: String?
    /// The SSE `id:` field.
    public var lastEventID: String?
    /// `event:` when present, otherwise a top-level `"type"` string in JSON data.
    /// Most chat APIs put the discriminator in the payload rather than the SSE field.
    public var type: String?
    /// Redacted payload. JSON is re-serialized compactly with long strings elided.
    public var data: String
    /// Text this event contributes to a streamed answer, when one could be found.
    public var text: String?
    /// Size of the payload as received, before redaction or elision.
    public var byteCount: Int
    /// The payload was shortened: a long string was elided or the data was cut.
    public var isTruncated: Bool

    public init(
        id: Int,
        offset: TimeInterval,
        event: String? = nil,
        lastEventID: String? = nil,
        type: String? = nil,
        data: String,
        text: String? = nil,
        byteCount: Int,
        isTruncated: Bool = false
    ) {
        self.id = id
        self.offset = offset
        self.event = event
        self.lastEventID = lastEventID
        self.type = type
        self.data = data
        self.text = text
        self.byteCount = byteCount
        self.isTruncated = isTruncated
    }
}

/// The parsed side of a `text/event-stream` response.
public struct NetworkStreamLog: Codable, Equatable, Sendable {
    /// Most recent events, oldest first. Bounded; see ``droppedEventCount``.
    public var events: [NetworkStreamEvent]
    /// Every event seen, including dropped ones.
    public var totalEventCount: Int
    /// Bytes received on the stream.
    public var totalByteCount: Int
    /// Oldest events evicted to keep memory bounded.
    public var droppedEventCount: Int

    public init(
        events: [NetworkStreamEvent] = [],
        totalEventCount: Int = 0,
        totalByteCount: Int = 0,
        droppedEventCount: Int = 0
    ) {
        self.events = events
        self.totalEventCount = totalEventCount
        self.totalByteCount = totalByteCount
        self.droppedEventCount = droppedEventCount
    }

    public var firstEventOffset: TimeInterval? {
        droppedEventCount == 0 ? events.first?.offset : nil
    }

    /// The streamed answer, joined from every event that carried text.
    public var assembledText: String {
        events.compactMap(\.text).joined()
    }
}

/// A raw event before redaction.
struct ServerSentEventFields: Equatable, Sendable {
    var event: String?
    var id: String?
    var data: String
}

/// Incremental `text/event-stream` parser.
///
/// Chunks can split a line, or a multi-byte character, anywhere; bytes are
/// buffered until a full line is available. Lines end in LF or CRLF.
struct ServerSentEventParser: Sendable {
    private var buffer = Data()
    private var event: String?
    private var id: String?
    private var dataLines: [String] = []

    mutating func feed(_ data: Data) -> [ServerSentEventFields] {
        buffer.append(data)
        var dispatched: [ServerSentEventFields] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            buffer.removeSubrange(buffer.startIndex...newline)

            if let event = process(String(decoding: line, as: UTF8.self)) {
                dispatched.append(event)
            }
        }
        return dispatched
    }

    /// Dispatches whatever is left when the stream ends without a blank line.
    mutating func finish() -> ServerSentEventFields? {
        if !buffer.isEmpty {
            _ = process(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        return dispatch()
    }

    private mutating func process(_ line: String) -> ServerSentEventFields? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "data": dataLines.append(String(value))
        case "event": event = String(value)
        case "id": id = String(value)
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEventFields? {
        defer {
            event = nil
            dataLines.removeAll()
        }
        guard !dataLines.isEmpty || event != nil else { return nil }
        // `id` persists across events per the spec; `event` and `data` do not.
        return ServerSentEventFields(event: event, id: id, data: dataLines.joined(separator: "\n"))
    }
}
