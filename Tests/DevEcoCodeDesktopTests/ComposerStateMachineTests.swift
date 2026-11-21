import XCTest
@testable import DevEcoCodeDesktop

/// Unit tests for the pure composer state machine. Every transition is
/// exercised without networking or SwiftUI so send / queue / edit contracts
/// stay verifiable independently of the store.
@MainActor
final class ComposerStateMachineTests: XCTestCase {
    private func attachment(_ name: String) -> PendingAttachment {
        PendingAttachment(mime: "text/plain", filename: name, url: "file:///tmp/\(name)", thumbnail: nil)
    }

    func testSubmitCapturesSnapshotAndClearsComposer() {
        var state = ComposerState()
        state.draft = "  hello  "
        state.attachments = [attachment("a.txt")]

        let submission = state.submit(model: "p/m", variant: "high", isBusy: false)

        XCTAssertEqual(submission?.snapshot.text, "hello")
        XCTAssertEqual(submission?.snapshot.model, "p/m")
        XCTAssertEqual(submission?.snapshot.variant, "high")
        XCTAssertEqual(submission?.snapshot.attachments.map(\.filename), ["a.txt"])
        XCTAssertEqual(submission?.queued, false)
        XCTAssertEqual(state.draft, "")
        XCTAssertTrue(state.attachments.isEmpty)
    }

    func testSubmitWhileBusyMarksQueued() {
        var state = ComposerState()
        state.draft = "prompt"

        XCTAssertEqual(state.submit(model: nil, variant: nil, isBusy: true)?.queued, true)
    }

    func testSubmitEmptyDraftReturnsNil() {
        var state = ComposerState()
        state.draft = "   \n  "
        XCTAssertNil(state.submit(model: nil, variant: nil, isBusy: false))
    }

    func testEnqueueRemoveAndReorder() {
        var state = ComposerState()
        let first = QueuedPrompt(text: "first", model: nil)
        let second = QueuedPrompt(text: "second", model: nil)
        let third = QueuedPrompt(text: "third", model: nil)
        state.enqueue(first)
        state.enqueue(second)
        state.enqueue(third)

        state.moveQueued(id: third.id, before: first.id)
        XCTAssertEqual(state.queue.map(\.text), ["third", "first", "second"])

        _ = state.removeQueued(id: first.id)
        XCTAssertEqual(state.queue.map(\.text), ["third", "second"])
    }

    func testEditQueuedRequeuesCurrentDraftWithoutLoss() {
        var state = ComposerState()
        let queued = QueuedPrompt(text: "queued", model: nil)
        state.enqueue(queued)
        state.draft = "draft"
        state.attachments = [attachment("draft.txt")]

        state.editQueued(queued, model: nil, variant: nil)

        XCTAssertEqual(state.draft, "queued")
        XCTAssertTrue(state.attachments.isEmpty)
        XCTAssertEqual(state.queue.map(\.text), ["draft"])
        XCTAssertEqual(state.queue.first?.attachments.map(\.filename), ["draft.txt"])
    }

    func testEditQueuedWithEmptyDraftRestoresAttachments() {
        var state = ComposerState()
        let queued = QueuedPrompt(
            text: "with attachment",
            model: nil,
            attachments: [attachment("queued.txt")]
        )
        state.enqueue(queued)

        state.editQueued(queued, model: nil, variant: nil)

        XCTAssertEqual(state.draft, "with attachment")
        XCTAssertEqual(state.attachments.map(\.filename), ["queued.txt"])
        XCTAssertTrue(state.queue.isEmpty)
    }
}
