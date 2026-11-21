import Foundation

/// Pure, send-queue-attachment state machine for one session's composer.
///
/// Holds no references to networking or UI so every transition is unit
/// testable. `SessionStore` builds a value from its published properties,
/// applies a transition, then writes the result back.
struct ComposerState {
    var draft = ""
    var attachments: [SessionStore.PendingAttachment] = []
    var queue: [SessionStore.QueuedPrompt] = []

    /// Result of submitting the current draft. `snapshot` is immutable;
    /// `queued` tells the caller whether it belongs in the wait queue.
    struct Submission {
        let snapshot: SessionStore.PromptSnapshot
        let queued: Bool
    }

    /// Captures the draft into an immutable snapshot, clears the composer,
    /// and reports whether the caller should queue (busy) or send directly.
    mutating func submit(
        model: String?,
        variant: String?,
        isBusy: Bool
    ) -> Submission? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let snapshot = SessionStore.PromptSnapshot(
            text: text,
            model: model,
            variant: variant,
            attachments: attachments
        )
        draft = ""
        attachments = []
        return Submission(snapshot: snapshot, queued: isBusy)
    }

    mutating func enqueue(_ prompt: SessionStore.QueuedPrompt, atFront: Bool = false) {
        if atFront {
            queue.insert(prompt, at: 0)
        } else {
            queue.append(prompt)
        }
    }

    @discardableResult
    mutating func removeQueued(id: UUID) -> QueuedPrompt? {
        let removed = queue.first { $0.id == id }
        queue.removeAll { $0.id == id }
        return removed
    }

    mutating func moveQueued(id: UUID, before targetID: UUID) {
        guard id != targetID,
              let from = queue.firstIndex(where: { $0.id == id }),
              queue.contains(where: { $0.id == targetID }) else { return }
        let item = queue.remove(at: from)
        let insertAt = queue.firstIndex(where: { $0.id == targetID }) ?? queue.count
        queue.insert(item, at: insertAt)
    }

    /// Pulls a queued prompt back into the composer. Any in-progress draft is
    /// re-queued ahead of the rest so neither text is lost.
    mutating func editQueued(
        _ prompt: SessionStore.QueuedPrompt,
        model: String?,
        variant: String?
    ) {
        removeQueued(id: prompt.id)

        let currentText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentText.isEmpty {
            let current = SessionStore.PromptSnapshot(
                text: currentText,
                model: model,
                variant: variant,
                attachments: attachments
            )
            enqueue(SessionStore.QueuedPrompt(prompt: current), atFront: true)
            attachments = []
        }
        draft = prompt.text
        let existing = Set(attachments.map(\.id))
        attachments.append(contentsOf: prompt.attachments.filter { !existing.contains($0.id) })
    }

    mutating func addAttachment(_ attachment: SessionStore.PendingAttachment) {
        attachments.append(attachment)
    }

    mutating func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    mutating func removeAttachments(ids: Set<UUID>) {
        attachments.removeAll { ids.contains($0.id) }
    }
}
