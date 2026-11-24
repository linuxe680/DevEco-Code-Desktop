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
    func testShrinkingTargetDoesNotReplayFromSeed() async throws {
        let reveal = StreamingReveal()
        let long = String(repeating: "先显示很长的一段内容。", count: 6)
        let shorter = "服务端改写了这一段。"

        reveal.update(target: long, isStreaming: true)
        try await waitUntilFinished(reveal, timeout: 3)
        XCTAssertEqual(reveal.text, long)

        // A shorter rewrite must clamp in place; rewinding to the seed made
        // the visible answer flash and re-type from the beginning.
        reveal.update(target: shorter, isStreaming: true)
        XCTAssertEqual(reveal.text, shorter)
        reveal.update(target: shorter, isStreaming: false)
        try await waitUntilFinished(reveal, timeout: 3)
        XCTAssertEqual(reveal.text, shorter)
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
