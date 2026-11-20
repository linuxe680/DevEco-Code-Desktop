import XCTest
import SwiftUI
import AppKit
@testable import DevEcoCodeDesktop

/// v0.5 P2 additions: ⌘F highlight rendering and oversized-image downscaling.
@MainActor
final class P2FeatureTests: XCTestCase {

    // MARK: ⌘F highlight

    func testHighlightAllOccurrencesCaseInsensitive() {
        let text = "abc AbC xabcx"
        let attributed = try? XCTUnwrap(highlightedAttributedString(text, query: "abc"))
        let highlighted = attributed!.runs
            .filter { $0.backgroundColor != nil }
            .map { String(attributed!.characters[$0.range]) }
        XCTAssertEqual(highlighted, ["abc", "AbC", "abc"])
    }

    func testHighlightNoMatchReturnsNil() {
        XCTAssertNil(highlightedAttributedString("hello world", query: "missing"))
        XCTAssertNil(highlightedAttributedString("hello", query: ""))
    }

    func testHighlightPreservesPlainText() {
        let attributed = try? XCTUnwrap(highlightedAttributedString("say 你好 then 你好 again", query: "你好"))
        XCTAssertEqual(String(attributed!.characters), "say 你好 then 你好 again")
        let highlighted = attributed!.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(highlighted.count, 2)
    }

    // MARK: Oversized image downscale

    // MARK: Per-session model/variant restore (regression: switching sessions
    // used to clobber the stored variant via the didSet cascade)

    func testSessionSwitchRestoresModelAndVariant() {
        AppSettings.sessionModels = [:]
        AppSettings.sessionVariants = [:]
        AppSettings.defaultSessionModel = ""
        defer {
            AppSettings.sessionModels = [:]
            AppSettings.sessionVariants = [:]
            AppSettings.defaultSessionModel = ""
        }
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.selectedModel = "prov/A"
        store.selectedVariant = "high"

        store.select("s2")
        store.selectedModel = "prov/B"
        store.selectedVariant = "low"

        store.select("s1")
        XCTAssertEqual(store.selectedModel, "prov/A", "session's model pick must survive a round trip")
        XCTAssertEqual(store.selectedVariant, "high", "session's variant must not be clobbered by the restore cascade")
    }

    func testSessionWithoutPickFallsBackToGlobalDefault() {
        AppSettings.sessionModels = ["s2": "prov/B"]
        AppSettings.defaultSessionModel = "prov/D"
        defer {
            AppSettings.sessionModels = [:]
            AppSettings.defaultSessionModel = ""
        }
        let store = SessionStore()
        store.selectedSessionID = nil
        store.select("s1")
        XCTAssertEqual(store.selectedModel, "prov/D", "no per-session entry should fall back to the app default")

        store.select("s2")
        XCTAssertEqual(store.selectedModel, "prov/B")
    }

    func testSessionWithoutPickFallsBackToServerDefault() {
        AppSettings.sessionModels = [:]
        AppSettings.defaultSessionModel = ""
        defer {
            AppSettings.sessionModels = [:]
            AppSettings.defaultSessionModel = ""
        }
        let store = SessionStore()
        store.serverDefaultModel = "magpie/workbuddy/hy4flash"
        store.selectedSessionID = nil
        store.select("s1")
        XCTAssertEqual(
            store.selectedModel,
            "magpie/workbuddy/hy4flash",
            "a brand-new session should preselect the server's configured model"
        )
    }

    func testAppDefaultModelTakesPrecedenceOverServerDefault() {
        AppSettings.sessionModels = [:]
        AppSettings.defaultSessionModel = "prov/A"
        defer {
            AppSettings.sessionModels = [:]
            AppSettings.defaultSessionModel = ""
        }
        let store = SessionStore()
        store.serverDefaultModel = "magpie/workbuddy/hy4flash"
        store.selectedSessionID = nil
        store.select("s1")
        XCTAssertEqual(store.selectedModel, "prov/A")
    }


    private func makePNG(width: Int, height: Int, noise: Bool) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: NSColorSpaceName.deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))).fill()
        NSGraphicsContext.restoreGraphicsState()
        if noise, let bitmap = rep.bitmapData {
            // Per-pixel random bytes: incompressible, like a real screenshot.
            arc4random_buf(bitmap, width * height * 4)
        }
        return rep.representation(using: .png, properties: [:])!
    }

    func testDownscaleCapsLongestSide() throws {
        let png = makePNG(width: 3000, height: 2000, noise: true)
        XCTAssertGreaterThan(png.count, SessionStore.maxImageBytes / 2, "noise image should be large like a real screenshot")
        let downscaled = try XCTUnwrap(SessionStore.downscaledImage(from: png))
        let image = try XCTUnwrap(NSImage(data: downscaled))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 1568)
    }

    func testDownscaleKeepsSmallImagesUnchanged() throws {
        let png = makePNG(width: 400, height: 300, noise: false)
        XCTAssertNil(SessionStore.downscaledImage(from: png), "small images should skip compression")
    }
}
