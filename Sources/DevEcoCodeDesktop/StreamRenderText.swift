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
        var lastCompleteFence: Int?
        var firstIncompleteFence: Int?
        var inFence = false
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("```") else { continue }
            if inFence {
                lastCompleteFence = index
                inFence = false
            } else {
                inFence = true
                firstIncompleteFence = index
            }
        }

        var boundary = lines.count - 1
        if inFence, let fenceStart = firstIncompleteFence ?? lastCompleteFence {
            boundary = fenceStart
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
        let lineStartOffset = prefixParts.reduce(0) { $0 + $1.utf16.count + 1 }
        let tailStart = text.index(text.startIndex, offsetBy: min(lineStartOffset, text.utf16.count))
        let liveTail = String(text[tailStart...])
        return Split(stablePrefix: stablePrefix, liveTail: liveTail)
    }
}
