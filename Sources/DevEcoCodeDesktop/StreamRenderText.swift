import Foundation

/// Splits a partially streamed assistant reply into a Markdown-safe prefix
/// and a plain-text tail. The prefix is rendered by the full rich renderer;
/// the tail is rendered as live text so an unfinished fence/link/bold marker
/// cannot repaint the whole bubble on every delta.
enum StreamRenderText {
    struct Split {
        let stablePrefix: String
        let liveTail: String

        var hasStablePrefix: Bool { !stablePrefix.isEmpty }
        var hasLiveTail: Bool { !liveTail.isEmpty }
    }

    static func split(_ text: String) -> Split {
        guard !text.isEmpty else {
            return Split(stablePrefix: "", liveTail: "")
        }

        let lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false))
        var openFenceStart: Int?
        var lastCompleteFence: Int?
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("```") else { continue }
            if openFenceStart != nil {
                openFenceStart = nil
                lastCompleteFence = index
            } else {
                openFenceStart = index
            }
        }

        var boundary: Int
        if let fenceStart = openFenceStart {
            boundary = fenceStart
        } else if lastCompleteFence == lines.count - 1 {
            // The reply currently ends on the closing fence. Keep that line in
            // the stable prefix; leaving it in the live tail rendered a second
            // stray "```" below the code block.
            boundary = lines.count
        } else {
            boundary = lines.count - 1
        }
        boundary = max(0, boundary)

        var prefixParts: [Substring] = []
        if boundary > 0 {
            prefixParts = Array(lines.prefix(boundary))
            while prefixParts.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                prefixParts.removeLast()
            }
        }
        let stablePrefix = prefixParts.isEmpty
            ? ""
            : prefixParts.joined(separator: "\n") + "\n"
        let liveTail = lines.dropFirst(prefixParts.count).joined(separator: "\n")
        return Split(stablePrefix: stablePrefix, liveTail: liveTail)
    }

    /// Plain-text tail for the live bubble. While the typewriter is still
    /// revealing glyphs the caret is appended to the tail itself; a caret on
    /// its own line only appears when the tail is empty (e.g. the reply
    /// currently ends on a completed code fence).
    static func liveTailText(_ split: Split, showCaret: Bool) -> String {
        let tail = split.liveTail
        guard showCaret else { return tail }
        return tail + "▍"
    }

    /// Display split for a bubble. While the reply is live the last line stays
    /// plain text (unfinished markup must not repaint the bubble); once it is
    /// finished the whole text is stable so its final line still gets inline
    /// Markdown styling.
    static func displaySplit(_ text: String, isLive: Bool) -> Split {
        guard !isLive else { return split(text) }
        guard !text.isEmpty else { return Split(stablePrefix: "", liveTail: "") }
        return Split(stablePrefix: text.hasSuffix("\n") ? text : text + "\n", liveTail: "")
    }

    /// Whether a transcript row is the live tail that should type itself out.
    /// `isSending` flips true the moment the user submits, before the server
    /// has appended the new user message, so checking "last row" alone made
    /// the previous finished reply replay its whole typewriter pass.
    static func shouldTypewrite(_ message: MessageRecord, isSending: Bool, isLast: Bool) -> Bool {
        isSending
            && isLast
            && message.info.role == "assistant"
            && message.info.time?.completed == nil
    }
}
