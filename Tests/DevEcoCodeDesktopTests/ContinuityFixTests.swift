import XCTest
@testable import DevEcoCodeDesktop

@MainActor
final class ContinuityFixTests: XCTestCase {
    private var savedHistory: [String] = []
    private var savedTitles: [String: String] = [:]
    private var savedManual: [String] = []

    override func setUp() {
        super.setUp()
        savedHistory = AppSettings.promptHistory
        savedTitles = AppSettings.clientAutoTitles
        savedManual = AppSettings.manuallyRenamedSessionIDs
        AppSettings.clientAutoTitles = [:]
        AppSettings.manuallyRenamedSessionIDs = []
    }

    override func tearDown() {
        AppSettings.promptHistory = savedHistory
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
}
