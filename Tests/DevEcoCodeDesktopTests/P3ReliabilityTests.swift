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
