import XCTest
@testable import DevEcoCodeDesktop

/// Store-layer performance baselines (GUI rendering is measured separately
/// against a running app; these quantify the data pipeline costs).
@MainActor
final class PerformanceTests: XCTestCase {
    private static let bigText = String(
        repeating: "Paragraph with **bold** text and `inline code`.\n\n```swift\nlet value = 42 // answer\n```\n\n",
        count: 120
    ) // ~9 KB of mixed prose/code, typical of a long assistant reply

    func testMarkdownParsePerformance() {
        // Baseline for the per-flush re-parse of the streaming bubble.
        measure {
            _ = parseMarkdownSegments(Self.bigText)
        }
    }

    func testMarkdownCachesReturnStableValues() {
        let prose = "# Summary\n\nA paragraph with **bold** text.\n"
        let firstSegments = parseMarkdownSegments(prose)
        let firstBlocks = parseMarkdownProseBlocks(prose)

        XCTAssertEqual(parseMarkdownSegments(prose), firstSegments)
        XCTAssertEqual(parseMarkdownProseBlocks(prose), firstBlocks)
        XCTAssertTrue(markdownSegmentsCacheToken(for: prose) === markdownSegmentsCacheToken(for: prose))
        XCTAssertTrue(markdownProseBlocksCacheToken(for: prose) === markdownProseBlocksCacheToken(for: prose))
    }

    func testHugeStreamingMarkdownIsNotCached() {
        let huge = String(repeating: "streaming prefix ", count: 2_000)
        XCTAssertNil(markdownSegmentsCacheToken(for: huge))
        XCTAssertFalse(parseMarkdownSegments(huge).isEmpty)
    }

    func testPendingDeltaBufferIsBounded() {
        let store = SessionStore()
        store.selectedSessionID = "ses_delta_cap"
        store.appendForTesting(String(repeating: "x", count: 200_000), partID: "prt_huge")
        XCTAssertLessThanOrEqual(store.pendingDeltaBytesForTesting(partID: "prt_huge"), 64 * 1024)
    }

    func testDeltaPipelinePerformance() {
        let store = SessionStore()
        let partID = "prt_bench"
        store.messages = [MessageRecord(
            info: MessageInfo(id: "msg_1", role: "assistant", modelID: "m", providerID: "p"),
            parts: [Part(id: partID, type: "text", text: "")]
        )]
        store.selectedSessionID = "ses_1"

        func deltaEvent(_ n: Int) -> DevEvent {
            DevEvent(
                id: "evt_\(n)",
                type: "message.part.delta",
                properties: .object([
                    "sessionID": .string("ses_1"),
                    "messageID": .string("msg_1"),
                    "partID": .string(partID),
                    "field": .string("text"),
                    "delta": .string("更多流式文本，包含中文与 English 混排。"),
                ])
            )
        }

        // 300 deltas in a burst: buffers, occasional 8KB-cap flushes.
        measure {
            for i in 0..<300 {
                store.handle(deltaEvent(i))
            }
        }
        // Trailing buffered deltas must not be lost.
        store.handle(deltaEvent(999))
        XCTAssertGreaterThan(store.messages[0].parts[0].text?.count ?? 0, 0)
    }

    // MARK: Realistic 500-message session scale

    /// A 500-message transcript: alternating short user prompts, long
    /// assistant markdown replies, and tool parts — the shape of a full
    /// workday session. Rebuilt per call so measure iterations start equal.
    private func makeLargeSession(store: SessionStore) {
        var messages: [MessageRecord] = []
        messages.reserveCapacity(500)
        for i in 0..<250 {
            messages.append(MessageRecord(
                info: MessageInfo(id: "user_\(i)", role: "user", modelID: nil, providerID: nil),
                parts: [Part(id: "up_\(i)", type: "text", text: "Please review the error handling in module \(i) and refactor it.")]
            ))
            messages.append(MessageRecord(
                info: MessageInfo(id: "asst_\(i)", role: "assistant", modelID: "m", providerID: "p"),
                parts: [
                    Part(id: "at_\(i)", type: "text", text: Self.bigText),
                    Part(id: "ap_\(i)", type: "tool", tool: "edit"),
                ]
            ))
        }
        store.messages = messages
    }

    /// Delta pipeline at real session scale: quantifies the O(n) message
    /// lookup + append cost when 500 messages precede the streaming one.
    /// Compare against testDeltaPipelinePerformance (1 message, ~300 deltas).
    func test500MessageDeltaPipelinePerformance() {
        let store = SessionStore()
        makeLargeSession(store: store)
        store.selectedSessionID = "ses_1"
        let targetID = "asst_249"

        func deltaEvent(_ n: Int) -> DevEvent {
            DevEvent(
                id: "evt_\(n)",
                type: "message.part.delta",
                properties: .object([
                    "sessionID": .string("ses_1"),
                    "messageID": .string(targetID),
                    "partID": .string("at_249"),
                    "field": .string("text"),
                    "delta": .string("更多流式文本，包含中文与 English 混排。"),
                ])
            )
        }

        measure {
            // Rebuild per iteration: appended deltas would otherwise make
            // later iterations carry megabytes of text.
            makeLargeSession(store: store)
            for i in 0..<300 {
                store.handle(deltaEvent(i))
            }
        }
        XCTAssertGreaterThan(store.messages[499].parts[0].text?.count ?? 0, 0)
    }

    /// ⌘F search cost at 500-message scale: one case-insensitive pass over
    /// every message's text parts (what visibleMessages does per keystroke).
    func test500MessageSearchFilterPerformance() {
        let store = SessionStore()
        makeLargeSession(store: store)
        let query = "refactor"

        measure {
            var matches = 0
            for message in store.messages {
                for part in message.parts {
                    if (part.text ?? "").localizedCaseInsensitiveContains(query) {
                        matches += 1
                    }
                }
            }
            XCTAssertEqual(matches, 250)
        }
    }
}
