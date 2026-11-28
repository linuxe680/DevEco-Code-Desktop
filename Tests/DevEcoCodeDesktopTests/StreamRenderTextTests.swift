import XCTest
@testable import DevEcoCodeDesktop

final class StreamRenderTextTests: XCTestCase {
    func testModelChangeNoticeIsHiddenFromAnswerProse() {
        let text = "模型已从 DeepSeek-V4.1-Flash · WorkBuddy 更改为 Hy4 flash · WorkBuddy。\n这是真正的回答。"
        XCTAssertEqual(visiblePartText(text, useMarkdown: true), "这是真正的回答。")
    }

    func testModelChangeNoticeDetection() {
        XCTAssertTrue(isModelChangeNotice("模型已从 A 更改为 B。"))
        XCTAssertTrue(isModelChangeNotice("Model changed from A to B."))
        XCTAssertFalse(isModelChangeNotice("普通回答里提到了 model。"))
    }

    func testSingleLineStaysLive() {
        let split = StreamRenderText.split("正在输出第一行")
        XCTAssertTrue(split.stablePrefix.isEmpty)
        XCTAssertEqual(split.liveTail, "正在输出第一行")
    }

    func testCompletedLinesBecomeStablePrefix() {
        let split = StreamRenderText.split("第一行\n第二行\n第三行")
        XCTAssertEqual(split.stablePrefix, "第一行\n第二行\n")
        XCTAssertEqual(split.liveTail, "第三行")
    }

    func testUnterminatedFenceKeepsCompletedProseStable() {
        let split = StreamRenderText.split("标题\n\n```swift\nlet value = 42")
        XCTAssertEqual(split.stablePrefix, "标题\n")
        XCTAssertEqual(split.liveTail, "\n```swift\nlet value = 42")
    }

    func testCompletedFenceBecomesStablePrefix() {
        let split = StreamRenderText.split("示例：\n```swift\nlet value = 42\n```\n下一行")
        XCTAssertEqual(split.stablePrefix, "示例：\n```swift\nlet value = 42\n```\n")
        XCTAssertEqual(split.liveTail, "下一行")
    }

    func testReplyEndingOnClosingFenceIsFullyStable() {
        let split = StreamRenderText.split("示例：\n```swift\nlet value = 42\n```")
        XCTAssertEqual(split.stablePrefix, "示例：\n```swift\nlet value = 42\n```\n")
        XCTAssertTrue(split.liveTail.isEmpty, "the closing fence must not be rendered twice")
    }

    func testReplyEndingOnClosingFenceWithNewlineIsFullyStable() {
        let split = StreamRenderText.split("示例：\n```swift\nlet value = 42\n```\n")
        XCTAssertEqual(split.stablePrefix, "示例：\n```swift\nlet value = 42\n```\n")
        XCTAssertTrue(split.liveTail.isEmpty)
    }

    func testLiveTailKeepsStreamingTextWhileCaretIsShown() {
        let text = "第一行\n正在输出"
        let split = StreamRenderText.split(text)
        XCTAssertEqual(
            StreamRenderText.liveTailText(split, showCaret: true),
            "正在输出▍",
            "the streaming line must stay visible; only the caret is appended"
        )
        XCTAssertEqual(StreamRenderText.liveTailText(split, showCaret: false), "正在输出")
    }

    func testCaretStandsAloneWhenTailIsEmpty() {
        let split = StreamRenderText.split("示例：\n```swift\nlet v = 1\n```")
        XCTAssertEqual(
            StreamRenderText.liveTailText(split, showCaret: true),
            "▍"
        )
    }

    func testEmojiInStablePrefixDoesNotBreakTailIndex() {
        let split = StreamRenderText.split("😀 第一行\n第二行 👨‍👩‍👧‍👦\n正在输出")
        XCTAssertEqual(split.stablePrefix, "😀 第一行\n第二行 👨‍👩‍👧‍👦\n")
        XCTAssertEqual(split.liveTail, "正在输出")
    }

    func testEmojiBeforeUnterminatedFence() {
        let split = StreamRenderText.split("🎉 示例\n\n```swift\nlet value = \"😀\"")
        XCTAssertEqual(split.stablePrefix, "🎉 示例\n")
        XCTAssertEqual(split.liveTail, "\n```swift\nlet value = \"😀\"")
    }

    func testEmojiOnlyTrailingLineStaysLive() {
        let split = StreamRenderText.split("第一行\n😀")
        XCTAssertEqual(split.stablePrefix, "第一行\n")
        XCTAssertEqual(split.liveTail, "😀")
    }

    func testFinishedReplyRendersEntirelyAsStableMarkdown() {
        let text = "第一行\n最后一行 **粗体**"
        let split = StreamRenderText.displaySplit(text, isLive: false)
        XCTAssertEqual(split.stablePrefix, text + "\n")
        XCTAssertTrue(split.liveTail.isEmpty, "a finished reply must not keep a plain-text tail")
    }

    func testFinishedReplyKeepsTrailingNewlineUnchanged() {
        let split = StreamRenderText.displaySplit("最后一行\n", isLive: false)
        XCTAssertEqual(split.stablePrefix, "最后一行\n")
        XCTAssertTrue(split.liveTail.isEmpty)
    }

    func testLiveReplyStillUsesPlainTextTail() {
        let split = StreamRenderText.displaySplit("第一行\n正在输出 **未完成", isLive: true)
        XCTAssertEqual(split.stablePrefix, "第一行\n")
        XCTAssertEqual(split.liveTail, "正在输出 **未完成")
    }

    func testFinishedLastReplyDoesNotTypewriteWhenNextPromptSends() {
        let finished = MessageRecord(
            info: MessageInfo(
                id: "msg_assistant",
                role: "assistant",
                time: MessageTime(created: 1, completed: 2)
            ),
            parts: []
        )
        XCTAssertFalse(StreamRenderText.shouldTypewrite(finished, isSending: true, isLast: true))
    }

    func testRunningAssistantTailTypewrites() {
        let running = MessageRecord(
            info: MessageInfo(
                id: "msg_assistant",
                role: "assistant",
                time: MessageTime(created: 1, completed: nil)
            ),
            parts: []
        )
        XCTAssertTrue(StreamRenderText.shouldTypewrite(running, isSending: true, isLast: true))
        XCTAssertFalse(StreamRenderText.shouldTypewrite(running, isSending: false, isLast: true))
    }
}
