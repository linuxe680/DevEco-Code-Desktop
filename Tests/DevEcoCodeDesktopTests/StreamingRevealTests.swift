import XCTest
@testable import DevEcoCodeDesktop

final class StreamingRevealTests: XCTestCase {
    @MainActor
    func testShortReplyFinishesRevealingAfterStreamEnds() async throws {
        let reveal = StreamingReveal()
        let target = "这是一段会先显示开头几个字，然后继续打字的回复。"

        reveal.update(target: target, isStreaming: true)
        XCTAssertLessThan(reveal.text.count, target.count)

        // The network run ends immediately after the burst; the typewriter
        // must still drain its backlog instead of freezing at the seed glyphs.
        reveal.update(target: target, isStreaming: false)
        try await waitUntilFinished(reveal, timeout: 3)

        XCTAssertEqual(reveal.text, target)
    }

    @MainActor
    func testRepeatedUpdatesDoNotSpawnCompetingTicks() async throws {
        let reveal = StreamingReveal()
        let target = String(repeating: "流式文本", count: 12)

        for end in stride(from: 2, through: target.count, by: 2) {
            reveal.update(
                target: String(target.prefix(end)),
                isStreaming: end < target.count
            )
        }
        reveal.update(target: target, isStreaming: false)
        try await waitUntilFinished(reveal, timeout: 5)

        XCTAssertEqual(reveal.text, target)
    }

    @MainActor
    private func waitUntilFinished(
        _ reveal: StreamingReveal,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !reveal.finished && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(reveal.finished, "typewriter stalled before reaching the full text")
    }
}
