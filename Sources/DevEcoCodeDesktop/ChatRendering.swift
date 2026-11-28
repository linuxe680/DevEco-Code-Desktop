import SwiftUI
import AppKit

private enum ChatLinkDetector {
    static func URLs(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [(Range<String.Index>, URL)] = []
        detector.enumerateMatches(in: text, options: [], range: nsRange) { match, _, _ in
            guard let match, let url = match.url else { return }
            guard let swiftRange = Range(match.range, in: text) else { return }
            result.append((swiftRange, url))
        }
        return result
    }
}

struct LinkText: View {
    let text: String
    var searchQuery: String = ""

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    var body: some View {
        let links = ChatLinkDetector.URLs(in: text)
        Group {
            if links.isEmpty && searchQuery.isEmpty {
                Text(text)
            } else {
                Text(buildAttributed(links))
                    .environment(\.openURL, OpenURLAction { url in
                        NSWorkspace.shared.open(url)
                        return .handled
                    })
            }
        }
        .font(.system(size: ChatTypography.body(chatFontSize)))
        .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func buildAttributed(_ links: [(range: Range<String.Index>, url: URL)]) -> AttributedString {
        var attributed = AttributedString()
        var cursor = text.startIndex
        for link in links {
            guard link.range.lowerBound >= cursor else { continue }
            attributed += AttributedString(String(text[cursor..<link.range.lowerBound]))
            var chunk = AttributedString(String(text[link.range]))
            chunk.link = link.url
            chunk.foregroundColor = .accentColor
            chunk.underlineStyle = .single
            attributed += chunk
            cursor = link.range.upperBound
        }
        attributed += AttributedString(String(text[cursor...]))
        applySearchHighlight(to: &attributed, query: searchQuery)
        return attributed
    }
}

/// Highlights every case-insensitive match in place, keeping any existing
/// styling (links) underneath. Shared by the live plain-text bubble, which
/// bypasses the Markdown renderer and therefore ⌘F's own highlighting.
func applySearchHighlight(to attributed: inout AttributedString, query: String) {
    guard !query.isEmpty else { return }
    var searchStart = attributed.startIndex
    while searchStart < attributed.endIndex,
          let hit = attributed[searchStart...].range(
              of: query,
              options: [.caseInsensitive, .diacriticInsensitive],
              locale: nil
          ) {
        attributed[hit].backgroundColor = Color.yellow.opacity(0.45)
        searchStart = hit.upperBound
    }
}

@ViewBuilder
func linkText(_ text: String, searchQuery: String = "") -> some View {
    LinkText(text: text, searchQuery: searchQuery)
}

struct ModelGroup: Identifiable {
    let provider: String
    let choices: [ModelChoice]

    var id: String { provider }
}

/// Measured height of the queued-prompt strip, so the floating "Back to
/// latest" pill can clear it without hard-coding a per-row height.
struct QueuedStripHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
