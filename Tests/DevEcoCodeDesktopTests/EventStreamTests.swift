import XCTest
@testable import DevEcoCodeDesktop

final class EventStreamTests: XCTestCase {
    private var stream: EventStream!
    private var events: [DevEvent]!

    override func setUp() {
        super.setUp()
        stream = EventStream()
        events = []
        stream.onEvent = { [weak self] event in self?.events.append(event) }
    }

    func testFrameSplitInsideMultiByteCharacter() {
        let payload = #"{"type":"message.part.delta","properties":{"sessionID":"s1","messageID":"m1","partID":"p1","delta":"你好世界"}}"#
        let frame = Data("data: \(payload)\n\n".utf8)

        // Split inside the multi-byte character 界 (last 6 bytes are 界" }}).
        let cut = frame.count - 4
        stream.ingest(frame.subdata(in: 0..<cut))
        XCTAssertTrue(events.isEmpty, "should not emit before the frame terminator arrives")
        stream.ingest(frame.subdata(in: cut..<frame.count))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "message.part.delta")
        XCTAssertEqual(events[0].property("delta"), "你好世界")
    }

    func testMultipleFramesInOneChunk() {
        let chunk = Data((
            #"data: {"type":"a","id":"1"}"# + "\n\n" +
            #"data: {"type":"b","id":"2"}"# + "\n\n"
        ).utf8)
        stream.ingest(chunk)
        XCTAssertEqual(events.map(\.type), ["a", "b"])
    }

    func testMultipleDataLinesAreJoined() {
        let chunk = Data((
            #"data: {"type":"b","properties":"# + "\n" +
            #"data: {"id":"3"}}"# + "\n\n"
        ).utf8)
        stream.ingest(chunk)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "b")
        XCTAssertEqual(events[0].property("id"), "3")
    }

    func testCRLFTerminator() {
        let chunk = Data((#"data: {"type":"crlf","properties":{"id":"4"}}"# + "\r\n\r\n").utf8)
        stream.ingest(chunk)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "crlf")
        XCTAssertEqual(events[0].property("id"), "4")
    }

    func testNonDataLinesAreIgnored() {
        let chunk = Data("event: message\ndata: {\"type\":\"e\"}\n: keepalive comment\n\n".utf8)
        stream.ingest(chunk)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "e")
    }

    func testPartialFrameIsBuffered() {
        stream.ingest(Data("data: {\"type\":\"par".utf8))
        XCTAssertTrue(events.isEmpty)
        stream.ingest(Data("tial\"}\n\n".utf8))
        XCTAssertEqual(events.map(\.type), ["partial"])
    }
}
