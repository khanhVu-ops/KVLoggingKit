import Foundation
import XCTest
@testable import KVLoggingNetwork

final class ServerSentEventsTests: XCTestCase {
    // MARK: - Parser

    func testParserJoinsLinesSplitAcrossChunks() {
        var parser = ServerSentEventParser()
        let wire = "data: {\"type\":\"chunk\",\"content\":\"Xin chào\"}\r\n\r\nevent: done\nid: 7\ndata: a\ndata: b\n\n"
        let bytes = Array(wire.utf8)
        var events: [ServerSentEventFields] = []

        // Split inside the multi-byte "à" and inside the CRLF.
        for chunk in [bytes[0..<31], bytes[31..<52], bytes[52...]] {
            events += parser.feed(Data(chunk))
        }

        XCTAssertEqual(events, [
            ServerSentEventFields(event: nil, id: nil, data: #"{"type":"chunk","content":"Xin chào"}"#),
            ServerSentEventFields(event: "done", id: "7", data: "a\nb")
        ])
    }

    func testParserIgnoresCommentsAndFlushesTheLastEventOnFinish() {
        var parser = ServerSentEventParser()
        XCTAssertEqual(parser.feed(Data(": keep-alive\n\ndata: tail".utf8)), [])
        XCTAssertEqual(parser.finish(), ServerSentEventFields(event: nil, id: nil, data: "tail"))
        XCTAssertNil(parser.finish())
    }

    // MARK: - Redaction

    func testEventTakesItsTypeFromJSONAndExtractsText() {
        let event = NetworkLogRedactor.default.streamEvent(
            from: .init(data: #"{"type":"chunk","content":"Hello","access_token":"secret"}"#),
            id: 0,
            offset: 0.5
        )

        XCTAssertEqual(event.type, "chunk")
        XCTAssertEqual(event.text, "Hello")
        XCTAssertFalse(event.data.contains("secret"))
        XCTAssertFalse(event.isTruncated)
    }

    func testLongStringsAreElidedAndMediaContributesNoText() {
        let audio = String(repeating: "A", count: 4_000)
        let event = NetworkLogRedactor.default.streamEvent(
            from: .init(data: #"{"type":"audio_chunk","content":"\#(audio)"}"#),
            id: 0,
            offset: 0
        )

        XCTAssertTrue(event.isTruncated)
        XCTAssertFalse(event.data.contains(audio))
        XCTAssertTrue(event.data.contains("elided"))
        XCTAssertNil(event.text)
        XCTAssertGreaterThan(event.byteCount, 4_000)
    }

    func testNonTextEventTypesContributeNoText() {
        let event = NetworkLogRedactor.default.streamEvent(
            from: .init(data: #"{"type":"activity","content":"Searching in web…"}"#),
            id: 0,
            offset: 0
        )
        XCTAssertNil(event.text)
    }

    func testOpenAIDeltaShapeIsRecognised() {
        let event = NetworkLogRedactor.default.streamEvent(
            from: .init(data: #"{"choices":[{"delta":{"content":"Hi"}}]}"#),
            id: 0,
            offset: 0
        )
        XCTAssertEqual(event.text, "Hi")
    }

    // MARK: - Recorder

    func testRecorderShowsEventsWhileStreamingAndKeepsThemOnCompletion() async throws {
        let store = NetworkLogStore()
        let recorder = NetworkLogRecorder(store: store, streamPublishInterval: 0)
        let key = NetworkTaskKey(owner: self, taskIdentifier: 1)
        let request = URLRequestSnapshot(URLRequest(url: URL(string: "https://api.example.com/interact")!))
        let response = HTTPResponseSnapshot(statusCode: 200, headers: ["Content-Type": "text/event-stream"])

        await recorder.begin(key, request: request)
        await recorder.receive(key, response: response)
        await recorder.receiveStreamData(key, data: Data("data: {\"type\":\"chunk\",\"content\":\"Hel\"}\n\n".utf8))

        let liveRecords = await store.all()
        let live = try XCTUnwrap(liveRecords.first)
        XCTAssertEqual(live.state, .pending)
        XCTAssertEqual(live.statusCode, 200)
        XCTAssertEqual(live.stream?.events.count, 1)

        await recorder.receiveStreamData(key, data: Data("data: {\"type\":\"chunk\",\"content\":\"lo\"}\n\ndata: {\"type\":\"done\"}".utf8))
        await recorder.complete(
            key,
            request: request,
            response: response,
            responseData: nil,
            error: nil,
            metrics: nil
        )

        let records = await store.all()
        let record = try XCTUnwrap(records.first)
        let stream = try XCTUnwrap(record.stream)
        XCTAssertEqual(record.state, .succeeded)
        XCTAssertEqual(stream.totalEventCount, 3)
        XCTAssertEqual(stream.events.map(\.type), ["chunk", "chunk", "done"])
        XCTAssertEqual(stream.assembledText, "Hello")
        XCTAssertEqual(record.response?.body.text?.hasPrefix("data: "), true)
    }

    func testRecorderDropsTheOldestEventsPastItsLimit() async throws {
        let store = NetworkLogStore()
        let recorder = NetworkLogRecorder(store: store, maximumStreamEvents: 2)
        let key = NetworkTaskKey(owner: self, taskIdentifier: 2)
        let request = URLRequestSnapshot(URLRequest(url: URL(string: "https://api.example.com/interact")!))
        let response = HTTPResponseSnapshot(statusCode: 200, headers: ["Content-Type": "text/event-stream"])

        // Delegate mode: no live feed, the whole body arrives on completion.
        await recorder.complete(
            key,
            request: request,
            response: response,
            responseData: Data("data: 1\n\ndata: 2\n\ndata: 3\n\n".utf8),
            error: nil,
            metrics: nil
        )

        let records = await store.all()
        let stream = try XCTUnwrap(records.first?.stream)
        XCTAssertEqual(stream.events.map(\.data), ["2", "3"])
        XCTAssertEqual(stream.events.map(\.id), [1, 2])
        XCTAssertEqual(stream.droppedEventCount, 1)
        XCTAssertEqual(stream.totalEventCount, 3)
    }
}
