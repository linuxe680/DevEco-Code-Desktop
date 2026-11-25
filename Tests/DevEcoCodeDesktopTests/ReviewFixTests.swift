import XCTest
@testable import DevEcoCodeDesktop

@MainActor
final class ReviewFixTests: XCTestCase {
    // MARK: - Failure classification

    func testBareNumbersInFreeTextDoNotLookLikeHTTPStatuses() {
        XCTAssertEqual(FailureKind.classify("generated 500 tokens"), .unknown)
        XCTAssertEqual(FailureKind.classify("request 404 in transcript"), .unknown)
        XCTAssertEqual(FailureKind.classify("rate 429 per minute"), .unknown)
    }

    func testExplicitStatusFormsAndAPIErrorStillClassify() {
        XCTAssertEqual(FailureKind.classify("HTTP 500 internal server error"), .server)
        XCTAssertEqual(FailureKind.classify("status 401"), .auth)
        XCTAssertEqual(APIError.status(403, "forbidden").kind, .auth)
        XCTAssertEqual(APIError.status(429, "rate limit").kind, .quota)
    }

    // MARK: - Slash command payload

    func testCommandRequestBodyKeepsVariantAndAttachments() throws {
        let attachment = PendingAttachment(
            mime: "image/png",
            filename: "shot.png",
            url: "data:image/png;base64,AA==",
            thumbnail: nil
        )
        let data = SessionStore.commandRequestBody(
            command: "review",
            arguments: "file.swift",
            model: "provider/model",
            variant: "high",
            attachments: [attachment]
        )
        let body = try XCTUnwrap(data).jsonObject() as? [String: Any]
        let json = try XCTUnwrap(body)

        XCTAssertEqual(json["command"] as? String, "review")
        XCTAssertEqual(json["arguments"] as? String, "file.swift")
        XCTAssertEqual(json["variant"] as? String, "high")
        // Command endpoint takes a plain model string; prompt_async takes an
        // object. Sending the object here is rejected with HTTP 400.
        XCTAssertEqual(json["model"] as? String, "provider/model")

        let parts = json["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 1)
        XCTAssertEqual(parts?.first?["type"] as? String, "file")
        XCTAssertEqual(parts?.first?["filename"] as? String, "shot.png")
        XCTAssertNil(parts?.first?["text"], "command endpoint rejects text parts")
    }

    func testCommandRequestBodyAlwaysIncludesRequiredArguments() throws {
        let data = SessionStore.commandRequestBody(
            command: "review",
            arguments: nil,
            model: nil,
            variant: nil,
            attachments: []
        )
        let json = try XCTUnwrap(try XCTUnwrap(data).jsonObject() as? [String: Any])
        XCTAssertEqual(json["arguments"] as? String, "")
        XCTAssertNil(json["parts"])
    }

    func testPromptRequestBodyIncludesVariantForNormalSends() throws {
        let prompt = PromptSnapshot(
            text: "hello",
            model: "p/m",
            variant: "medium",
            attachments: []
        )
        let json = try XCTUnwrap(SessionStore.promptRequestBody(prompt)).jsonObject() as? [String: Any]
        let object = try XCTUnwrap(json)
        XCTAssertEqual(object["variant"] as? String, "medium")
        XCTAssertEqual((object["parts"] as? [[String: Any]])?.first?["text"] as? String, "hello")
    }

    // MARK: - SSE response policy

    func testSSERejectsBadStatusAndNonEventStreamContent() {
        XCTAssertFalse(EventStream.isRejectableResponse(statusCode: 200, contentType: "text/event-stream"))
        XCTAssertFalse(EventStream.isRejectableResponse(statusCode: 200, contentType: ""))
        XCTAssertTrue(EventStream.isRejectableResponse(statusCode: 401, contentType: "text/event-stream"))
        XCTAssertTrue(EventStream.isRejectableResponse(statusCode: 404, contentType: "text/event-stream"))
        XCTAssertTrue(EventStream.isRejectableResponse(statusCode: 200, contentType: "text/html; charset=utf-8"))
    }

    func testLargeFrameSplitAcrossManyChunksStillDecodes() {
        let stream = EventStream()
        defer { stream.disconnect() }
        var received: [DevEvent] = []
        stream.onEvent = { received.append($0) }

        let longText = String(repeating: "a", count: 50_000)
        let payload = try! JSONSerialization.data(withJSONObject: [
            "type": "probe",
            "properties": ["text": longText],
        ])
        let frame = Data("data: ".utf8) + payload + Data("\n\n".utf8)
        var offset = 0
        while offset < frame.count {
            let end = min(offset + 997, frame.count)
            stream.ingest(frame.subdata(in: offset..<end))
            offset = end
        }

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.property("text"), longText)
    }

    func testRejectedResponseDoesNotReportADisconnect() {
        let stream = EventStream()
        defer { stream.disconnect() }
        var disconnects = 0
        var fatalStatuses: [Int?] = []
        stream.onDisconnect = { disconnects += 1 }
        stream.onFatalResponse = { status, _ in fatalStatuses.append(status) }

        let url = URL(string: "http://127.0.0.1:4096/event")!
        let task = URLSession.shared.dataTask(with: url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!

        var disposition: URLSession.ResponseDisposition?
        stream.urlSession(URLSession.shared, dataTask: task, didReceive: response) {
            disposition = $0
        }
        stream.urlSession(URLSession.shared, task: task, didCompleteWithError: nil)

        XCTAssertEqual(disposition, .cancel)
        XCTAssertEqual(fatalStatuses, [401])
        XCTAssertEqual(disconnects, 0, "a fatal HTTP response must not trigger the reconnect loop")
        XCTAssertFalse(stream.isConnected)
    }

    func testFatalResponseClearsLiveSessionState() async {
        let store = SessionStore()
        store.currentServerBaseURLProvider = {
            URL(string: "http://127.0.0.1:4100")!
        }
        store.connect(baseURL: URL(string: "http://127.0.0.1:4096")!)
        let url = URL(string: "http://127.0.0.1:4096/event")!
        let task = URLSession.shared.dataTask(with: url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        )!
        store.eventStream.urlSession(URLSession.shared, dataTask: task, didReceive: response) { _ in }
        await Task.yield()

        XCTAssertTrue(store.streamRejected)
        XCTAssertFalse(store.isReconnecting)
        XCTAssertNotNil(store.errorMessage)

        store.retryStreamConnection()
        XCTAssertFalse(store.streamRejected)
        XCTAssertNil(store.errorMessage)
    }

    // MARK: - Session completion paths

    func testIdleStatusAloneFinishesRunAndMarksUnread() throws {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.handle(try Self.event(
            #"{"type":"session.status","properties":{"sessionID":"s2","status":{"type":"busy"}}}"#
        ))
        XCTAssertEqual(store.indicator(for: "s2")?.kind, .busy)

        store.handle(try Self.event(
            #"{"type":"session.status","properties":{"sessionID":"s2","status":{"type":"idle"}}}"#
        ))

        XCTAssertEqual(
            store.indicator(for: "s2")?.kind,
            .unread,
            "servers that report completion only via session.status must still surface the finished run"
        )
    }

    private static func event(_ json: String) throws -> DevEvent {
        try JSONDecoder.deveco.decode(DevEvent.self, from: Data(json.utf8))
    }

    // MARK: - Provider deletion fallback

    func testDefaultModelFallsBackWhenItsProviderIsDeleted() {
        let other = ServerModel(id: "m2", name: "M2", providerID: "p2", limit: nil, variants: nil)
        XCTAssertEqual(
            ProviderStore.replacementDefaultModel(
                current: "p1/old",
                deletedProviderID: "p1",
                availableModels: [other],
                clientDefault: ""
            ),
            "p2/m2"
        )
        XCTAssertNil(
            ProviderStore.replacementDefaultModel(
                current: "p2/m2",
                deletedProviderID: "p1",
                availableModels: [other],
                clientDefault: ""
            )
        )
        XCTAssertEqual(
            ProviderStore.replacementDefaultModel(
                current: "p1/old",
                deletedProviderID: "p1",
                availableModels: [],
                clientDefault: ""
            ),
            ""
        )
    }
}

private extension Data {
    func jsonObject() throws -> Any {
        try JSONSerialization.jsonObject(with: self)
    }
}
