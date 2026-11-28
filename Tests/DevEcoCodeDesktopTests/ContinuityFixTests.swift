import XCTest
@testable import DevEcoCodeDesktop

@MainActor
final class ContinuityFixTests: XCTestCase {
    private var savedHistory: [String] = []
    private var savedSaveHistory = true
    private var savedDrafts: [String: String] = [:]
    private var savedTitles: [String: String] = [:]
    private var savedManual: [String] = []

    override func setUp() {
        super.setUp()
        savedHistory = AppSettings.promptHistory
        savedSaveHistory = AppSettings.savePromptHistory
        savedDrafts = AppSettings.sessionDrafts
        savedTitles = AppSettings.clientAutoTitles
        savedManual = AppSettings.manuallyRenamedSessionIDs
        AppSettings.clientAutoTitles = [:]
        AppSettings.manuallyRenamedSessionIDs = []
    }

    override func tearDown() {
        AppSettings.promptHistory = savedHistory
        AppSettings.savePromptHistory = savedSaveHistory
        AppSettings.sessionDrafts = savedDrafts
        AppSettings.clientAutoTitles = savedTitles
        AppSettings.manuallyRenamedSessionIDs = savedManual
        super.tearDown()
    }

    func testClientTitleStateClearsForDeletedSession() throws {
        let store = SessionStore()
        let session = Session(id: "ses_delete", title: "首条提问", directory: nil, time: nil, revert: nil)
        store.sessions = [session]
        store.setClientTitle("首条提问", for: session.id)
        let event = try JSONDecoder.deveco.decode(
            DevEvent.self,
            from: Data(#"{"type":"session.deleted","properties":{"sessionID":"ses_delete"}}"#.utf8)
        )

        store.handle(event)

        XCTAssertNil(AppSettings.clientAutoTitles["ses_delete"])
        XCTAssertFalse(AppSettings.manuallyRenamedSessionIDs.contains("ses_delete"))
    }

    func testTrailingDeltaFlushesWithoutAnotherEvent() throws {
        let store = SessionStore()
        store.selectedSessionID = "ses_delta_tail"
        store.messages = [MessageRecord(
            info: MessageInfo(id: "msg_delta_tail", role: "assistant", modelID: nil, providerID: nil),
            parts: [Part(id: "prt_delta_tail", type: "text", text: "")]
        )]
        let event = try JSONDecoder.deveco.decode(
            DevEvent.self,
            from: Data(#"{"type":"message.part.delta","properties":{"sessionID":"ses_delta_tail","messageID":"msg_delta_tail","partID":"prt_delta_tail","field":"text","delta":"尾字"}}"#.utf8)
        )

        store.handle(event)

        let expectation = expectation(description: "trailing delta flushed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            XCTAssertEqual(store.messages[0].parts[0].text, "尾字")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testManualRenameDropsClientTitleAuthority() throws {
        let store = SessionStore()
        let session = Session(id: "ses_manual", title: "旧标题", directory: nil, time: nil, revert: nil)
        store.sessions = [session]
        store.setClientTitle("首条提问", for: session.id)
        store.markManuallyRenamed(session.id)
        let event = try JSONDecoder.deveco.decode(
            DevEvent.self,
            from: Data(#"{"type":"session.updated","properties":{"info":{"id":"ses_manual","title":"服务端标题"}}}"#.utf8)
        )

        store.handle(event)

        XCTAssertEqual(store.session(for: session.id)?.title, "服务端标题")
        XCTAssertNil(AppSettings.clientAutoTitles[session.id])
    }

    func testSearchablePathKeepsSourceFiles() {
        XCTAssertTrue(SessionStore.isSearchablePath("Sources/App.swift"))
        XCTAssertFalse(SessionStore.isSearchablePath("logs/events.log"))
        XCTAssertFalse(SessionStore.isSearchablePath("build/cache.tmp"))
    }

    func testSubmitClearsDraftAndAdvancesToken() {
        let store = SessionStore()
        store.connect(baseURL: URL(string: "http://127.0.0.1:4199")!)
        store.selectedSessionID = "ses_submit"
        store.draft = "first prompt"
        let oldToken = store.draftToken
        store.send()
        XCTAssertEqual(store.draft, "")
        XCTAssertNotEqual(store.draftToken, oldToken)
        XCTAssertEqual(AppSettings.promptHistory.last, "first prompt")
    }

    func testEmptySubmitDoesNotAdvanceToken() {
        let store = SessionStore()
        store.connect(baseURL: URL(string: "http://127.0.0.1:4199")!)
        store.selectedSessionID = "ses_empty"
        store.draft = "  "
        let oldToken = store.draftToken
        store.send()
        XCTAssertEqual(store.draft, "  ")
        XCTAssertEqual(store.draftToken, oldToken)
    }

    func testPromptHistoryCanBeDisabled() {
        AppSettings.savePromptHistory = false
        let before = AppSettings.promptHistory
        let store = SessionStore()
        store.connect(baseURL: URL(string: "http://127.0.0.1:4199")!)
        store.selectedSessionID = "ses_no_history"
        store.draft = "do not remember"
        store.send()
        XCTAssertEqual(AppSettings.promptHistory, before)
    }

    func testDraftsPersistAcrossStoreRecreation() {
        AppSettings.sessionDrafts = ["ses_draft": "unsent text"]
        let store = SessionStore()
        store.sessions = [Session(id: "ses_draft", title: "Draft", directory: nil, time: nil, revert: nil)]
        store.select("ses_draft")
        XCTAssertEqual(store.draft, "unsent text")

        store.draft = "edited draft"
        store.flushDrafts()
        XCTAssertEqual(AppSettings.sessionDrafts["ses_draft"], "edited draft")
    }
}
