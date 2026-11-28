import XCTest
@testable import DevEcoCodeDesktop

@MainActor
final class SessionIsolationTests: XCTestCase {
    private var savedModels: [String: String] = [:]
    private var savedVariants: [String: String] = [:]
    private var savedDrafts: [String: String] = [:]
    private var savedDefaultModel = ""

    override func setUp() {
        super.setUp()
        savedModels = AppSettings.sessionModels
        savedVariants = AppSettings.sessionVariants
        savedDrafts = AppSettings.sessionDrafts
        savedDefaultModel = AppSettings.defaultSessionModel
        AppSettings.sessionModels = [:]
        AppSettings.sessionVariants = [:]
        AppSettings.sessionDrafts = [:]
        AppSettings.defaultSessionModel = ""
        UserDefaults.standard.removeObject(forKey: "cachedSessions")
        UserDefaults.standard.removeObject(forKey: "cachedSelectedSession")
    }

    override func tearDown() {
        AppSettings.sessionModels = savedModels
        AppSettings.sessionVariants = savedVariants
        AppSettings.sessionDrafts = savedDrafts
        AppSettings.defaultSessionModel = savedDefaultModel
        super.tearDown()
    }

    private func event(_ json: String) throws -> DevEvent {
        try JSONDecoder.deveco.decode(DevEvent.self, from: Data(json.utf8))
    }

    func testBusyStateDoesNotLeakToAnotherSession() throws {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.handle(try event(
            #"{"type":"session.status","properties":{"sessionID":"s1","status":{"type":"busy"}}}"#
        ))
        XCTAssertTrue(store.isSending)

        store.select("s2")
        XCTAssertFalse(store.isSending, "an idle session must not inherit another session's run")

        store.handle(try event(
            #"{"type":"session.status","properties":{"sessionID":"s2","status":{"type":"busy"}}}"#
        ))
        XCTAssertTrue(store.isSending)

        store.handle(try event(
            #"{"type":"session.status","properties":{"sessionID":"s2","status":{"type":"idle"}}}"#
        ))
        XCTAssertFalse(store.isSending)

        store.select("s1")
        XCTAssertTrue(store.isSending, "the original session must still be running")
    }

    func testRetryInfoIsScopedToSession() throws {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.handle(try event(
            #"{"type":"session.status","properties":{"sessionID":"s1","status":{"type":"retry","attempt":2,"message":"rate limited"}}}"#
        ))
        XCTAssertEqual(store.retryInfo, "attempt 2 · rate limited")

        store.select("s2")
        XCTAssertNil(store.retryInfo)

        store.select("s1")
        XCTAssertEqual(store.retryInfo, "attempt 2 · rate limited")
    }

    func testAttachmentsAreScopedToSession() {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.addFileAttachment(url: URL(fileURLWithPath: "/tmp/first.txt"))
        XCTAssertEqual(store.attachments.map(\.filename), ["first.txt"])

        store.select("s2")
        XCTAssertTrue(store.attachments.isEmpty)
        store.addFileAttachment(url: URL(fileURLWithPath: "/tmp/second.txt"))
        XCTAssertEqual(store.attachments.map(\.filename), ["second.txt"])

        store.select("s1")
        XCTAssertEqual(store.attachments.map(\.filename), ["first.txt"])
    }

    func testEditingQueuedPromptRestoresItsSnapshot() {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.selectedModel = "provider/B"
        store.selectedVariant = "low"

        let attachment = SessionStore.PendingAttachment(
            mime: "text/plain",
            filename: "queued.txt",
            url: "file:///tmp/queued.txt",
            thumbnail: nil
        )
        let queued = SessionStore.QueuedPrompt(
            text: "queued question",
            model: "provider/A",
            variant: "high",
            attachments: [attachment]
        )

        store.draft = "work in progress"
        store.editQueued(queued)

        XCTAssertEqual(store.draft, "queued question")
        XCTAssertEqual(store.queuedPrompts.first?.text, "work in progress")
        XCTAssertEqual(store.attachments.map(\.filename), ["queued.txt"])
        XCTAssertEqual(store.queuedPrompts.first?.model, "provider/A")
        XCTAssertEqual(store.queuedPrompts.first?.prompt.variant, "high")
    }

    func testEditQueuedRestoresQueuedModelVariant() {
        let store = SessionStore()
        store.selectedSessionID = "ses_edit_model"
        store.selectedModel = "provider/current"
        store.selectedVariant = "low"
        let queued = SessionStore.QueuedPrompt(
            text: "queued with model",
            model: "provider/original",
            variant: "high"
        )

        store.editQueued(queued)

        XCTAssertEqual(store.draft, "queued with model")
        XCTAssertEqual(store.selectedModel, "provider/original")
        XCTAssertEqual(store.selectedVariant, "high")
    }

    func testPermissionAndQuestionIndicatorsAreSessionScoped() throws {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.handle(try event(
            #"{"type":"permission.asked","properties":{"id":"p1","sessionID":"s1","permission":"bash","patterns":["git status"]}}"#
        ))
        store.handle(try event(
            #"{"type":"permission.asked","properties":{"id":"p2","sessionID":"s1","permission":"edit","patterns":["README.md"]}}"#
        ))
        store.handle(try event(
            #"{"type":"question.asked","properties":{"id":"q1","sessionID":"s2","questions":[{"question":"Which one?","header":"Choice","options":[{"label":"A"}]}]}}"#
        ))

        XCTAssertEqual(store.indicator(for: "s1"), .init(kind: .permission, count: 2))
        XCTAssertEqual(store.indicator(for: "s2"), .init(kind: .question, count: 1))
        XCTAssertNil(store.indicator(for: "s3"))
    }

    func testBackgroundFailureSurvivesSessionSwitch() throws {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.handle(try event(
            #"{"type":"session.error","properties":{"sessionID":"s2","error":{"name":"ProviderError","data":{"message":"model not found"}}}}"#
        ))

        XCTAssertEqual(store.indicator(for: "s2"), .init(kind: .failed, count: 1))
        XCTAssertNil(store.inlineError)

        store.select("s2")
        XCTAssertEqual(store.inlineError?.sessionID, "s2")
        XCTAssertEqual(store.inlineError?.message, "ProviderError: model not found")
        XCTAssertEqual(store.inlineError?.kind, .modelUnavailable)
    }

    func testAbortErrorDoesNotBecomeAnInlineFailure() throws {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.handle(try event(
            #"{"type":"session.error","properties":{"sessionID":"s1","error":{"name":"MessageAbortedError","data":{"message":"Aborted"}}}}"#
        ))

        XCTAssertNil(store.inlineError)
        XCTAssertNil(store.indicator(for: "s1"))
    }

    /// A retry that succeeds must clear the previous failure card; otherwise
    /// the conversation keeps an "model unavailable" banner below a reply.
    func testNewerAssistantOutputClearsTheStaleInlineError() throws {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.handle(try event(
            #"{"type":"message.updated","properties":{"sessionID":"s1","info":{"id":"m1","role":"user","time":{"created":1}}}}"#
        ))
        store.handle(try event(
            #"{"type":"session.error","properties":{"sessionID":"s1","error":{"name":"ProviderModelNotFoundError","data":{"message":"model not found"}}}}"#
        ))
        XCTAssertNotNil(store.inlineError)

        store.handle(try event(
            #"{"type":"message.updated","properties":{"sessionID":"s1","info":{"id":"m2","role":"assistant","time":{"created":2}}}}"#
        ))
        store.handle(try event(
            #"{"type":"message.part.updated","properties":{"sessionID":"s1","part":{"id":"p1","messageID":"m2","type":"text","text":"ok"}}}"#
        ))

        XCTAssertNil(store.inlineError)
        XCTAssertNil(store.indicator(for: "s1"))
    }

    func testFailureWithoutANewerTurnStaysVisible() throws {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.handle(try event(
            #"{"type":"message.updated","properties":{"sessionID":"s1","info":{"id":"m1","role":"user","time":{"created":1}}}}"#
        ))
        store.handle(try event(
            #"{"type":"session.error","properties":{"sessionID":"s1","error":{"name":"ProviderModelNotFoundError","data":{"message":"model not found"}}}}"#
        ))
        // A late update for the *same* tail (e.g. a finish part) must not
        // silently hide the failure the user still needs to act on.
        store.handle(try event(
            #"{"type":"message.part.updated","properties":{"sessionID":"s1","part":{"id":"p1","messageID":"m1","type":"text","text":"hi"}}}"#
        ))

        XCTAssertNotNil(store.inlineError)
    }

    func testDeletedSelectedSessionDoesNotSurfaceRaw404() {
        let error = APIError.status(404, #"{"name":"NotFoundError","data":{"message":"Session not found"}}"#)
        XCTAssertEqual(error.kind, .modelUnavailable)
        XCTAssertTrue(error.localizedDescription.contains("404"))
    }

    func testAPIErrorDescriptionDoesNotLeakStackTrace() {
        let body = #"{"name":"ProviderModelNotFoundError","data":{"message":"Model not found\n    at SessionPrompt.doExecute (/src/SessionPrompt.ts:333:31)"}}"#
        let error = APIError.status(500, body)
        XCTAssertEqual(
            error.localizedDescription,
            String(format: NSLocalizedString("Server error (%lld): %@", comment: ""), Int64(500), "Model not found")
        )
    }

    func testSessionDeletionEventClearsDeletedSessionState() throws {
        let store = SessionStore()
        store.sessions = [
            Session(id: "ses_delete", title: "to delete", directory: nil, time: nil, revert: nil)
        ]
        store.selectedSessionID = "ses_delete"
        store.handle(try event(
            #"{"type":"session.deleted","properties":{"sessionID":"ses_delete"}}"#
        ))

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selectedSessionID)
    }

    func testApplyingDeletionClearsTodosDiffsAndInlineError() throws {
        let store = SessionStore()
        store.sessions = [
            Session(id: "ses_dirty", title: "dirty", directory: nil, time: nil, revert: nil)
        ]
        store.selectedSessionID = "ses_dirty"
        store.handle(try event(
            #"{"type":"session.deleted","properties":{"sessionID":"ses_dirty"}}"#
        ))

        XCTAssertTrue(store.todos.isEmpty)
        XCTAssertTrue(store.diffs.isEmpty)
        XCTAssertNil(store.inlineError)
    }

    func testDisconnectClearsGlobalConsentAndSelection() throws {
        let store = SessionStore()
        store.selectedSessionID = "ses_old"
        store.handle(try event(
            #"{"type":"session.error","properties":{"error":"product agreement consent required"}}"#
        ))
        XCTAssertTrue(store.needsConsent)
        store.isCompacting = true
        store.errorMessage = "stale"
        store.disconnect()

        XCTAssertNil(store.selectedSessionID)
        XCTAssertFalse(store.needsConsent)
        XCTAssertFalse(store.isCompacting)
        XCTAssertNil(store.errorMessage)
    }

    func testDisconnectClearsDraftQueueAndMentionState() throws {
        let store = SessionStore()
        store.selectedSessionID = "ses_old"
        store.draft = "unsent draft"
        store.editQueued(SessionStore.QueuedPrompt(text: "queued text", model: nil))
        store.handle(try event(
            #"{"type":"permission.asked","properties":{"id":"p1","sessionID":"ses_old","permission":"bash","patterns":["x"]}}"#
        ))

        store.disconnect()

        XCTAssertEqual(store.draft, "")
        XCTAssertTrue(store.queuedPrompts.isEmpty)
        XCTAssertTrue(store.pendingPermissions.isEmpty)
        XCTAssertTrue(store.attachments.isEmpty)
        XCTAssertEqual(store.draftToken, store.draftToken)
    }

    func testPermissionReplyClearsPendingImmediately() throws {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        let request = PermissionRequest(
            id: "p_opt",
            sessionID: "s1",
            permission: "bash",
            patterns: ["x"],
            action: nil
        )
        store.handle(try event(
            #"{"type":"permission.asked","properties":{"id":"p_opt","sessionID":"s1","permission":"bash","patterns":["x"]}}"#
        ))
        XCTAssertEqual(store.pendingPermissions.count, 1)

        store.reply(to: request, reply: "once")

        XCTAssertTrue(store.pendingPermissions.isEmpty, "banner and Dock badge must clear before the network reply lands")
    }

    func testBackgroundCompletionBecomesUnreadAndClearsOnOpen() throws {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.handle(try event(
            #"{"type":"session.status","properties":{"sessionID":"s2","status":{"type":"busy"}}}"#
        ))
        store.handle(try event(
            #"{"type":"session.idle","properties":{"sessionID":"s2"}}"#
        ))

        XCTAssertEqual(store.indicator(for: "s2"), .init(kind: .unread, count: 1))

        store.select("s2")
        XCTAssertNil(store.indicator(for: "s2"))
    }

    func testQuestionDraftsAreIsolatedByRequestID() {
        let store = SessionStore()
        store.testSetQuestionDraft(for: "q1", index: 0, labels: ["A"])
        XCTAssertEqual(store.questionDraftSelections(for: "q1")[0], ["A"])
        XCTAssertTrue(store.questionDraftSelections(for: "q2").isEmpty)
        store.clearQuestionDraft(for: "q1")
        XCTAssertTrue(store.questionDraftSelections(for: "q1").isEmpty)
    }

    func testMessageSnapshotCacheIsBounded() {
        let store = SessionStore()
        for index in 0..<20 {
            let message = MessageRecord(
                info: MessageInfo(id: "m\(index)", role: "assistant"),
                parts: [Part(id: "p\(index)", type: "text", text: "cached \(index)")]
            )
            store.cacheMessagesForTesting([message], for: "s\(index)")
        }
        XCTAssertLessThanOrEqual(
            store.messageCacheEntryCountForTesting(),
            SessionStore.maxMessageCacheEntriesForTesting
        )
    }

    func testMessageSnapshotCacheEvictsUntilLargeEntryFits() {
        let store = SessionStore()
        let small = MessageRecord(
            info: MessageInfo(id: "m_small", role: "assistant"),
            parts: [Part(id: "p_small", type: "text", text: String(repeating: "a", count: 1_000))]
        )
        for index in 0..<8 {
            store.cacheMessagesForTesting([small], for: "s\(index)")
        }
        let huge = MessageRecord(
            info: MessageInfo(id: "m_huge", role: "assistant"),
            parts: [Part(id: "p_huge", type: "text", text: String(repeating: "b", count: 50_000))]
        )
        store.cacheMessagesForTesting([huge], for: "huge")
        XCTAssertLessThanOrEqual(
            store.messageCacheEntryCountForTesting(),
            SessionStore.maxMessageCacheEntriesForTesting
        )
        XCTAssertLessThanOrEqual(store.messageCacheCharactersForTesting, 400_000)
    }

    func testDisconnectResetsMessageCacheAccounting() {
        let store = SessionStore()
        let message = MessageRecord(
            info: MessageInfo(id: "m_disconnect", role: "assistant"),
            parts: [Part(id: "p_disconnect", type: "text", text: String(repeating: "x", count: 2_000))]
        )
        store.cacheMessagesForTesting([message], for: "s_disconnect")
        XCTAssertEqual(store.messageCacheCharactersForTesting, 2_000)

        store.disconnect()

        XCTAssertEqual(store.messageCacheEntryCountForTesting(), 0)
        XCTAssertEqual(store.messageCacheCharactersForTesting, 0)
    }
}
