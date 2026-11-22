import XCTest
@testable import DevEcoCodeDesktop

final class StreamRenderTextTests: XCTestCase {
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
}
