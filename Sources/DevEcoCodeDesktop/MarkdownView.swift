import SwiftUI
import AppKit

/// Attributed text with every occurrence of `query` highlighted. Used for
/// ⌘F in-message emphasis on plain-text (user) parts; nil = no matches.
func highlightedAttributedString(_ text: String, query: String) -> AttributedString? {
    guard !query.isEmpty, text.localizedCaseInsensitiveContains(query) else { return nil }
    var hits: [Range<String.Index>] = []
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
          let hit = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
        hits.append(hit)
        searchStart = hit.upperBound
    }
    guard !hits.isEmpty else { return nil }
    var result = AttributedString()
    var cursor = text.startIndex
    for hit in hits {
        result += AttributedString(String(text[cursor..<hit.lowerBound]))
        var highlighted = AttributedString(String(text[hit]))
        highlighted.backgroundColor = Color.yellow.opacity(0.45)
        result += highlighted
        cursor = hit.upperBound
    }
    result += AttributedString(String(text[cursor...]))
    return result
}

enum MarkdownSegment: Equatable {
    case text(String)
    case code(lang: String, code: String)
}

/// Streaming re-renders every visible bubble on each delta flush; these
/// caches keep per-frame work proportional to the changed message instead of
/// the whole visible transcript.
final class CachedBox<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}

enum MarkdownCache {
    static let segments = NSCache<NSString, CachedBox<[MarkdownSegment]>>()
    static let proseBlocks = NSCache<NSString, CachedBox<[MarkdownProseBlock]>>()
    static let inline = NSCache<NSString, CachedBox<AttributedString>>()
    /// Streaming parts change the full content on every delta. Caching every
    /// prefix kept all intermediate versions alive for the lifetime of the
    /// app — the main source of "长会话越聊越占内存" reports.
    static let maxCacheableContent = 16 * 1024

    static func configure() {
        segments.countLimit = 256
        segments.totalCostLimit = 16 * 1024 * 1024
        proseBlocks.countLimit = 256
        proseBlocks.totalCostLimit = 16 * 1024 * 1024
        inline.countLimit = 512
        inline.totalCostLimit = 32 * 1024 * 1024
    }

    static func key(_ parts: String...) -> NSString {
        parts.joined(separator: "|") as NSString
    }

    static func isCacheable(_ text: String) -> Bool {
        text.utf8.count <= maxCacheableContent
    }
}

/// Test hooks: NSCache returns the same box object on a hit, so tests can
/// verify the cache contract without timing thresholds or private mirrors.
func markdownSegmentsCacheToken(for content: String) -> AnyObject? {
    MarkdownCache.segments.object(forKey: content as NSString)
}

func markdownProseBlocksCacheToken(for text: String) -> AnyObject? {
    MarkdownCache.proseBlocks.object(forKey: text as NSString)
}

/// Splits assistant output into prose and fenced code blocks. An unterminated
/// fence (mid-stream) renders its tail as code, so the block appears styled
/// immediately instead of flashing as plain text.
func parseMarkdownSegments(_ content: String) -> [MarkdownSegment] {
    let cacheKey = content as NSString
    if let cached = MarkdownCache.segments.object(forKey: cacheKey)?.value {
        return cached
    }
    var segments: [MarkdownSegment] = []
    var textLines: [String] = []
    var codeLines: [String] = []
    var currentLang = ""
    var inCode = false

    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(line)
        if !inCode, line.hasPrefix("```") {
            if !textLines.isEmpty {
                segments.append(.text(textLines.joined(separator: "\n")))
                textLines = []
            }
            inCode = true
            currentLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            codeLines = []
        } else if inCode, line.hasPrefix("```") {
            segments.append(.code(lang: currentLang, code: codeLines.joined(separator: "\n")))
            inCode = false
            currentLang = ""
            codeLines = []
        } else if inCode {
            codeLines.append(line)
        } else {
            textLines.append(line)
        }
    }
    if inCode {
        segments.append(.code(lang: currentLang, code: codeLines.joined(separator: "\n")))
    } else if !textLines.isEmpty {
        segments.append(.text(textLines.joined(separator: "\n")))
    }
    if MarkdownCache.isCacheable(content) {
        MarkdownCache.segments.setObject(
            CachedBox(segments), forKey: cacheKey,
            cost: max(1, content.utf8.count)
        )
    }
    return segments
}

enum MarkdownProseBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(String)
    case numbered(number: Int, text: String)
    case quote(String)
    case systemNotice(String)
    case divider
}

/// A narrow set of model-generated bookkeeping lines. They are not user prose
/// and should not inherit the answer's body typography. Keep this conservative:
/// unknown lines stay normal paragraphs.
private func isSystemNoticeLine(_ text: String) -> Bool {
    let lowered = text.lowercased()
    if lowered.contains("模型已从") || lowered.contains("model changed") {
        return true
    }
    let markers = [
        "recalled ",
        "remembered ",
        "loaded skill ",
        "using skill ",
        "reading ",
        "searching ",
        "fetched ",
    ]
    guard markers.contains(where: { lowered.contains($0) }) else { return false }
    return lowered.contains("(") && lowered.contains(")")
}

/// Drops bookkeeping lines such as "💡 Recalled … (project)" while keeping
/// the real answer that follows them in the same text part.
func removingSystemNoticeLines(_ text: String) -> String {
    text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !isSystemNoticeLine(String($0.trimmingCharacters(in: .whitespaces))) }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Only assistant output carries model bookkeeping lines. User prompts are
/// verbatim: a prompt like "searching for X (in src)" must never be mistaken
/// for a notice and filtered down to an empty bubble.
func visiblePartText(_ text: String, useMarkdown: Bool) -> String {
    guard useMarkdown else {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let cleaned = removingSystemNoticeLines(text)
    return cleaned
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !isModelChangeNotice(String($0.trimmingCharacters(in: .whitespaces))) }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func systemNoticeText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "💡 ", with: "")
        .replacingOccurrences(of: "# ", with: "")
}

func isModelChangeNotice(_ text: String) -> Bool {
    text.contains("模型已从") || text.localizedCaseInsensitiveContains("model changed")
}

/// Splits prose into headings, lists, quotes, and paragraphs. Inline styling
/// (bold/italic/inline code) is still delegated to AttributedString.
func parseMarkdownProseBlocks(_ text: String) -> [MarkdownProseBlock] {
    let cacheKey = text as NSString
    if let cached = MarkdownCache.proseBlocks.object(forKey: cacheKey)?.value {
        return cached
    }
    var blocks: [MarkdownProseBlock] = []
    var paragraphLines: [String] = []

    func flushParagraph() {
        let paragraph = paragraphLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !paragraph.isEmpty {
            blocks.append(.paragraph(paragraph))
        }
        paragraphLines = []
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            flushParagraph()
            continue
        }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            flushParagraph()
            blocks.append(.divider)
            continue
        }

        let hashes = trimmed.prefix(while: { $0 == "#" })
        if (1...6).contains(hashes.count) {
            let rest = trimmed.dropFirst(hashes.count)
            if rest.first?.isWhitespace == true {
                let heading = String(rest).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty {
                    flushParagraph()
                    blocks.append(.heading(level: hashes.count, text: heading))
                    continue
                }
            }
        }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            flushParagraph()
            blocks.append(.bullet(String(trimmed.dropFirst(2))))
            continue
        }

        let pieces = trimmed.split(separator: " ", maxSplits: 1)
        if pieces.count == 2 {
            let marker = pieces[0]
            let numeric = marker.dropLast()
            let validMarker = marker.hasSuffix(".") || marker.hasSuffix(")")
            if validMarker, let number = Int(numeric) {
                flushParagraph()
                blocks.append(.numbered(number: number, text: String(pieces[1])))
                continue
            }
        }

        if trimmed.hasPrefix(">") {
            flushParagraph()
            let quote = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !quote.isEmpty {
                blocks.append(.quote(quote))
            }
            continue
        }

        if isSystemNoticeLine(trimmed) { continue }

        paragraphLines.append(trimmed)
    }

    flushParagraph()
    if MarkdownCache.isCacheable(text) {
        MarkdownCache.proseBlocks.setObject(
            CachedBox(blocks), forKey: cacheKey,
            cost: max(1, text.utf8.count)
        )
    }
    return blocks
}

/// Renders assistant prose with readable block formatting, and fenced blocks
/// as horizontally scrollable code cards.
struct MarkdownContentView: View {
    let content: String
    /// When set (⌘F active), prose segments highlight the matches.
    var searchQuery: String = ""

    var body: some View {
        let segments = parseMarkdownSegments(content)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    MarkdownProseView(text: text, highlightQuery: searchQuery)
                case .code(let lang, let code):
                    CodeBlockView(lang: lang, code: code)
                }
            }
        }
    }
}

private struct MarkdownProseView: View {
    let text: String
    var highlightQuery: String = ""

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    private var bodySize: CGFloat {
        ChatTypography.body(chatFontSize)
    }

    private var blockSpacing: CGFloat {
        max(5, bodySize * 0.42)
    }

    var body: some View {
        let blocks = parseMarkdownProseBlocks(text)
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownProseBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text, size: bodySize)
        case .heading(let level, let text):
            inlineText(
                text,
                size: ChatTypography.heading(chatFontSize, level: min(level, 3)),
                weight: .semibold
            )
            .padding(.top, level == 1 ? 3 : 1)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: bodySize, weight: .semibold))
                    .foregroundStyle(.secondary)
                inlineText(text, size: bodySize)
            }
            .padding(.leading, 3)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(number).")
                    .font(.system(size: bodySize, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: max(18, bodySize * 1.25), alignment: .trailing)
                inlineText(text, size: bodySize)
            }
        case .quote(let text):
            inlineText(text, size: bodySize)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: 2)
                }
        case .systemNotice:
            EmptyView()
        case .divider:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func inlineText(
        _ text: String,
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> some View {
        Group {
            if !highlightQuery.isEmpty,
               let highlighted = highlightedAttributedString(text, query: highlightQuery) {
                Text(highlighted)
            } else if let attributed = cachedInline(text, size: size, weight: weight) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(.system(size: size, weight: weight))
        .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Identical paragraphs across renders hit the cache; only the streaming
    /// bubble's tail paragraph re-parses per flush.
    private func cachedInline(
        _ text: String,
        size: CGFloat,
        weight: Font.Weight
    ) -> AttributedString? {
        let key = MarkdownCache.key("\(size)", "\(weight)", text)
        if let cached = MarkdownCache.inline.object(forKey: key)?.value {
            return cached
        }
        guard var attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) else { return nil }
        styleInlineCode(&attributed)
        if MarkdownCache.isCacheable(text) {
            MarkdownCache.inline.setObject(
                CachedBox(attributed), forKey: key,
                cost: max(1, text.utf8.count)
            )
        }
        return attributed
    }

    /// Codex-like inline richness: backticked tokens render on a subtle chip
    /// tint with monospaced digits — file names, flags, and code refs pop out
    /// of prose without switching to a full code block.
    private func styleInlineCode(_ attributed: inout AttributedString) {
        var styled = AttributedString()
        let runs = Array(attributed.runs)
        for run in runs {
            let range = run.range
            var chunk = AttributedString(attributed[range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                chunk.font = .system(size: bodySize - 1.5, weight: .medium, design: .monospaced)
                chunk.foregroundColor = .accentColor
                chunk.backgroundColor = Color.accentColor.opacity(0.10)
            } else if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                chunk.font = .system(size: bodySize, weight: .bold)
                chunk.foregroundColor = .primary
            } else if run.inlinePresentationIntent?.contains(.emphasized) == true {
                chunk.font = .system(size: bodySize, weight: .regular, design: .serif)
                chunk.foregroundColor = .secondary
            }
            styled.append(chunk)
        }
        attributed = styled
    }
}

private struct CodeBlockView: View {
    let lang: String
    let code: String

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? NSLocalizedString("code", comment: "code block fallback label") : lang)
                    .font(.system(size: ChatTypography.meta(chatFontSize), weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    copyCode()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: ChatTypography.meta(chatFontSize)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .help(NSLocalizedString("Copy code", comment: ""))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlight(code, language: lang))
                    .font(.system(
                        size: ChatTypography.code(chatFontSize),
                        weight: .regular,
                        design: .monospaced
                    ))
                    .lineSpacing(max(1, ChatTypography.lineSpacing(chatFontSize) * 0.35))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
        }
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.softStroke)
        )
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
