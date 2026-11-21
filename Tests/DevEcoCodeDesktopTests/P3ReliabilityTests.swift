import XCTest
@testable import DevEcoCodeDesktop

final class P3ReliabilityTests: XCTestCase {
    // MARK: FailureKind classification

    func testAuthFailures() {
        XCTAssertEqual(FailureKind.classify("Invalid API key provided", statusCode: nil), .auth)
        XCTAssertEqual(FailureKind.classify("Forbidden", statusCode: 403), .auth)
        XCTAssertEqual(FailureKind.classify("unauthorized: bad credentials", statusCode: nil), .auth)
    }

    func testQuotaFailures() {
        XCTAssertEqual(FailureKind.classify("rate limit exceeded, retry later", statusCode: nil), .quota)
        XCTAssertEqual(FailureKind.classify("insufficient quota", statusCode: 429), .quota)
        XCTAssertEqual(FailureKind.classify("billing problem", statusCode: nil), .quota)
    }

    func testModelUnavailableFailures() {
        XCTAssertEqual(FailureKind.classify("model not found: magpie/zcode/GLM-9", statusCode: nil), .modelUnavailable)
        XCTAssertEqual(FailureKind.classify("no such model", statusCode: 404), .modelUnavailable)
    }

    func testNetworkFailures() {
        XCTAssertEqual(FailureKind.classify("connection refused to 127.0.0.1:4096", statusCode: nil), .network)
        XCTAssertEqual(FailureKind.classify("request timed out", statusCode: nil), .network)
    }

    func testServerFailures() {
        XCTAssertEqual(FailureKind.classify("upstream exploded", statusCode: 502), .server)
        XCTAssertEqual(FailureKind.classify("internal server error", statusCode: nil), .server)
    }

    func testStatusCodeWinsOverAmbiguousText() {
        // A 401 whose body mentions "connection" still classifies as auth.
        XCTAssertEqual(FailureKind.classify("connection dropped while authorizing", statusCode: 401), .auth)
    }

    func testUnknownFallthrough() {
        XCTAssertEqual(FailureKind.classify("something odd happened", statusCode: nil), .unknown)
    }

    func testAbortedIsNotTreatedAsAFailure() {
        XCTAssertEqual(FailureKind.classify("MessageAbortedError: Aborted", statusCode: nil), .aborted)
        XCTAssertEqual(FailureKind.classify("MessageAbortedError: Aborted", statusCode: 500), .aborted)
        XCTAssertEqual(FailureKind.classify("User aborted", statusCode: nil), .aborted)
        XCTAssertEqual(FailureKind.classify("Tool execution aborted", statusCode: nil), .aborted)
    }

    // MARK: Diagnostics report

    @MainActor
    func testDiagnosticsReportContainsKeyFacts() {
        let server = ServerManager()
        let report = server.diagnosticsReport()
        XCTAssertTrue(report.contains("DevEco Code Desktop"), "should include app name")
        XCTAssertTrue(report.contains("Server state:"), "should include server state")
        XCTAssertTrue(report.contains("Data directory:"), "should include data dir")
        XCTAssertTrue(report.contains("Log file:"), "should include log path")
        XCTAssertTrue(report.contains("macOS:"), "should include OS version")
    }

    // MARK: Model recents & session pins (fixtures live on the class because
    // extensions cannot hold stored properties)

    var savedRecents: [String] = []
    var savedPins: [String] = []

    override func setUpWithError() throws {
        savedRecents = AppSettings.recentModels
        savedPins = AppSettings.pinnedSessionIDs
        AppSettings.recentModels = []
        AppSettings.pinnedSessionIDs = []
    }

    override func tearDownWithError() throws {
        AppSettings.recentModels = savedRecents
        AppSettings.pinnedSessionIDs = savedPins
    }
}

// MARK: Queue hardening regressions (2026-11-20 deep audit)

@MainActor
final class QueueHardeningTests: XCTestCase {
    func testEditQueuedPreservesExistingDraft() {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        let queued = SessionStore.QueuedPrompt(text: "queued question", model: nil)
        store.draft = "work in progress"
        store.editQueued(queued)
        // The queued text moves into the input; the unfinished draft is
        // re-queued instead of being overwritten into oblivion.
        XCTAssertEqual(store.draft, "queued question")
        XCTAssertEqual(store.queuedPrompts.first?.text, "work in progress")
        XCTAssertEqual(store.queuedPrompts.count, 1)
    }

    func testEditQueuedWithEmptyDraftDoesNotQueuePlaceholder() {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        let queued = SessionStore.QueuedPrompt(text: "queued question", model: nil)
        store.draft = "   "
        store.editQueued(queued)
        XCTAssertEqual(store.draft, "queued question")
        XCTAssertTrue(store.queuedPrompts.isEmpty, "whitespace draft must not become a queue entry")
    }

    func testSendWithoutSessionKeepsDraft() {
        let store = SessionStore()
        store.draft = "not lost"
        store.send()
        XCTAssertEqual(store.draft, "not lost", "sending with no session must keep the text in the input")
    }
}

@MainActor
extension P3ReliabilityTests {
    func testSearchablePathFiltersJunk() {
        XCTAssertFalse(SessionStore.isSearchablePath("debug/server.log"))
        XCTAssertFalse(SessionStore.isSearchablePath("build/tmp/cache.tmp"))
        XCTAssertFalse(SessionStore.isSearchablePath(".git/config"))
        XCTAssertFalse(SessionStore.isSearchablePath("node_modules/pkg/index.js"))
        XCTAssertTrue(SessionStore.isSearchablePath("src/app/main.swift"))
        XCTAssertTrue(SessionStore.isSearchablePath("README.md"))
    }

    func testMentionTokenSurvivesNewlines() {
        XCTAssertEqual(ChatView.mentionToken(in: "first line\n@src/ma"), "src/ma")
        XCTAssertEqual(ChatView.mentionToken(in: "@"), "")
        XCTAssertEqual(ChatView.mentionToken(in: "hello @world"), "world")
        XCTAssertNil(ChatView.mentionToken(in: "no mention here"))
    }

    // MARK: One-shot settings migrations (settingsVersion marker)

    private func withFreshDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let savedFont = defaults.object(forKey: AppSettings.Keys.chatFontSize)
        let savedVersion = defaults.object(forKey: AppSettings.Keys.settingsVersion)
        defer {
            if let savedFont { defaults.set(savedFont, forKey: AppSettings.Keys.chatFontSize) }
            else { defaults.removeObject(forKey: AppSettings.Keys.chatFontSize) }
            if let savedVersion { defaults.set(savedVersion, forKey: AppSettings.Keys.settingsVersion) }
            else { defaults.removeObject(forKey: AppSettings.Keys.settingsVersion) }
        }
        defaults.removeObject(forKey: AppSettings.Keys.chatFontSize)
        defaults.removeObject(forKey: AppSettings.Keys.settingsVersion)
        body()
    }

    func testSettingsMigrationMovesLegacyFontTo15() {
        withFreshDefaults {
            UserDefaults.standard.set(16.0, forKey: AppSettings.Keys.chatFontSize)
            AppSettings.registerDefaults()
            XCTAssertEqual(UserDefaults.standard.double(forKey: AppSettings.Keys.chatFontSize), 15.0)
            XCTAssertEqual(UserDefaults.standard.integer(forKey: AppSettings.Keys.settingsVersion), 1)
        }
    }

    func testSettingsMigrationKeepsLargerUserChoice() {
        withFreshDefaults {
            UserDefaults.standard.set(20.0, forKey: AppSettings.Keys.chatFontSize)
            AppSettings.registerDefaults()
            XCTAssertEqual(UserDefaults.standard.double(forKey: AppSettings.Keys.chatFontSize), 20.0)
        }
    }

    func testSettingsMigrationRunsOnce() {
        withFreshDefaults {
            UserDefaults.standard.set(16.0, forKey: AppSettings.Keys.chatFontSize)
            AppSettings.registerDefaults()
            // A later user pick of 16pt must survive relaunch.
            UserDefaults.standard.set(16.0, forKey: AppSettings.Keys.chatFontSize)
            AppSettings.registerDefaults()
            XCTAssertEqual(UserDefaults.standard.double(forKey: AppSettings.Keys.chatFontSize), 16.0)
        }
    }

    func testRecentModelsDedupeAndCap() {
        for id in ["a/x", "b/y", "a/x", "c/z", "d/w", "e/v", "f/u", "g/t"] {
            AppSettings.rememberRecentModel(id)
        }
        let recents = AppSettings.recentModels
        XCTAssertEqual(recents, ["g/t", "f/u", "e/v", "d/w", "c/z", "a/x"], "newest first, deduped, capped at six")
    }

    func testPinToggleRoundTrip() {
        let store = SessionStore()
        store.togglePinned("s1")
        XCTAssertEqual(store.pinnedSessionIDs, ["s1"])
        XCTAssertEqual(AppSettings.pinnedSessionIDs, ["s1"], "pins persist across restarts")

        store.togglePinned("s2")
        XCTAssertEqual(store.pinnedSessionIDs, ["s2", "s1"], "newest pin first")

        store.togglePinned("s2")
        XCTAssertEqual(store.pinnedSessionIDs, ["s1"])

        store.togglePinned("s1", pinned: true)
        XCTAssertEqual(store.pinnedSessionIDs, ["s1"], "explicit pin on an already-pinned session is a no-op")
    }

    func testDeletionRemovesPin() {
        let store = SessionStore()
        store.togglePinned("ses_gone")
        XCTAssertEqual(store.pinnedSessionIDs, ["ses_gone"])
        store.togglePinned("ses_gone", pinned: false)
        XCTAssertTrue(store.pinnedSessionIDs.isEmpty)
    }
}
