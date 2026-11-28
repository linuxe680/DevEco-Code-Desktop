import SwiftUI
import AppKit

/// Composer token meter: Claude-style ring + numeric readout for the full
/// request context of the last turn vs. the selected model's limit. The arc
/// shifts from blue to orange to red as the window fills.
struct ContextMeter: View {
    let used: Double
    let limit: Double?
    var tokens: MessageTokens?

    @State private var showDetails = false
    @State private var cursorPushed = false

    private var ratio: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }

    private var tint: Color {
        guard let ratio else { return .secondary }
        if ratio > 0.85 { return .red }
        if ratio > 0.6 { return .orange }
        return .blue
    }

    var body: some View {
        HStack(spacing: 6) {
            if let limit, limit > 0, let ratio {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.14), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(ratio, 0.001))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                .animation(.easeOut(duration: 0.3), value: ratio)
                Text("\(compactTokenCount(used)) / \(compactTokenCount(limit)) · \(Int((ratio * 100).rounded()))%")
                    .foregroundStyle(tint)
                    .monospacedDigit()
            } else {
                Text("\(compactTokenCount(used)) tokens")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            showDetails.toggle()
        }
        .onHover { hovering in
            if hovering && !cursorPushed {
                NSCursor.pointingHand.push()
                cursorPushed = true
            } else if !hovering && cursorPushed {
                NSCursor.pointingHand.pop()
                cursorPushed = false
            }
        }
        .onDisappear {
            if cursorPushed {
                NSCursor.pointingHand.pop()
                cursorPushed = false
            }
        }
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            ContextDetailsPopover(used: used, limit: limit, tokens: tokens)
        }
        .help(NSLocalizedString(
            "Context window usage — click for breakdown",
            comment: ""
        ))
    }
}

/// Claude-style context breakdown. The deveco server only reports aggregate
/// counters (input / cache.read / output), so those are shown honestly instead
/// of inventing system-prompt / tool splits the API does not expose.
private struct ContextDetailsPopover: View {
    let used: Double
    let limit: Double?
    let tokens: MessageTokens?

    private var inputTokens: Double { tokens?.input ?? 0 }
    private var cachedTokens: Double { tokens?.cache?.read ?? 0 }
    private var generatedTokens: Double {
        (tokens?.output ?? 0) + (tokens?.reasoning ?? 0)
    }
    private var freeSpace: Double {
        guard let limit, limit > 0 else { return 0 }
        return max(0, limit - used)
    }
    private var ratio: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(NSLocalizedString("Context window", comment: "context popover title"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let limit, limit > 0, let ratio {
                    Text("\(compactTokenCount(used)) / \(compactTokenCount(limit)) · \(Int((ratio * 100).rounded()))%")
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                } else {
                    Text(compactTokenCount(used))
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            if let limit, limit > 0, let ratio {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(ratio > 0.85 ? Color.red : (ratio > 0.6 ? Color.orange : Color.blue))
                            .frame(width: max(3, proxy.size.width * ratio))
                    }
                }
                .frame(height: 5)
            }
            Divider()
            row(color: .blue, label: NSLocalizedString("New input", comment: ""),
                amount: inputTokens, limit: limit)
            row(color: .orange, label: NSLocalizedString("Cached input", comment: ""),
                amount: cachedTokens, limit: limit)
            row(color: .purple, label: NSLocalizedString("Generated", comment: ""),
                amount: generatedTokens, limit: nil)
            row(color: .gray.opacity(0.5), label: NSLocalizedString("Free space", comment: ""),
                amount: freeSpace, limit: limit)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func row(color: Color, label: String, amount: Double, limit: Double?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            Spacer()
            Text(compactTokenCount(amount))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            if let limit, limit > 0 {
                Text(String(format: "%.1f%%", amount / limit * 100))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

/// Decoded image cache — bubbles re-render on every stream flush, and
/// re-decoding a multi-MB screenshot each time would spike the CPU.
enum ImageCache {
    static let cache = NSCache<NSString, NSImage>()
    static let maxCacheableBytes = 2 * 1024 * 1024

    static func configure() {
        cache.countLimit = 128
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    /// Bounds decoded bitmaps. A screenshot that arrives as a 12MP data URL
    /// otherwise stays resident at full size for the whole session.
    static let maxPixelDimension: CGFloat = 2048

    static func decoded(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return NSImage(data: data)
        }
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxPixelDimension else {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        let scale = maxPixelDimension / longest
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }
        return NSImage(cgImage: resized, size: NSSize(width: width, height: height))
    }
}

/// File attachment from a prompt or an agent message. Images render inline
/// (data: and file: URLs both verified in stored traffic); other types show
/// as a chip. Clicking opens the content.
struct AttachmentChip: View {
    let filename: String
    let mime: String?
    let urlString: String?
    @State private var showPreview = false

    private var isImage: Bool {
        mime?.hasPrefix("image/") == true
    }

    var body: some View {
        if isImage, let image = loadImage() {
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.softStroke))
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(filename.isEmpty ? NSLocalizedString("Image", comment: "attachment label") : filename)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(NSLocalizedString("Click to open", comment: "attachment hint"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 320)
            }
            .padding(6)
            .background(Theme.chromeFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.softStroke))
            .contentShape(Rectangle())
            .onTapGesture { showPreview = true }
            .help(NSLocalizedString("Open attachment", comment: ""))
            .sheet(isPresented: $showPreview) {
                ImagePreviewSheet(
                    image: image,
                    filename: filename.isEmpty ? NSLocalizedString("Image", comment: "attachment label") : filename,
                    onOpenExternally: open
                )
            }
        } else {
            chip
        }
    }

    private var chip: some View {
        Button {
            open()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.plaintext")
                    .foregroundStyle(Color.accentColor)
                Text(filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.chipFill)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.softStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Open attachment", comment: ""))
    }

    private func loadImage() -> NSImage? {
        guard let urlString else { return nil }
        let key = urlString as NSString
        if let cached = ImageCache.cache.object(forKey: key) {
            return cached
        }
        let data: Data?
        if urlString.hasPrefix("data:"), let url = URL(string: urlString) {
            data = try? Data(contentsOf: url)
        } else if let url = URL(string: urlString), url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = nil
        }
        guard let data, let image = ImageCache.decoded(data) else { return nil }
        if data.count <= ImageCache.maxCacheableBytes {
            let cost = max(1, data.count)
            ImageCache.cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    private func open() {
        guard let urlString else { return }
        if urlString.hasPrefix("data:") {
            // LaunchServices cannot open data URLs — materialize to a cache file.
            guard let url = URL(string: urlString), let data = try? Data(contentsOf: url),
                  let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let ext = mime == "image/jpeg" ? "jpg" : (mime == "image/gif" ? "gif" : "png")
            let fileURL = caches.appendingPathComponent("deveco-attachment-\(UUID().uuidString).\(ext)")
            try? data.write(to: fileURL)
            NSWorkspace.shared.open(fileURL)
            return
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// In-app image viewer. Clicking a transcript image should not bounce the
/// user into Preview.app for a quick look; external open stays one click away.
private struct ImagePreviewSheet: View {
    let image: NSImage
    let filename: String
    var onOpenExternally: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                Text(filename)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    onOpenExternally()
                } label: {
                    Label(NSLocalizedString("Open in Preview", comment: ""), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
                Button(NSLocalizedString("Done", comment: "")) {
                    dismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: max(240, geo.size.width), maxHeight: max(180, geo.size.height))
                        .padding(16)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .onExitCommand { dismiss() }
    }
}

/// deveco refuses model calls until its product agreement is accepted; this
/// card explains that and offers a one-click acceptance.
struct ConsentCard: View {
    let agreement: ProductAgreement?
    let isAccepting: Bool
    var onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.checkmark")
                    .foregroundStyle(.orange)
                Text(NSLocalizedString("Product agreement confirmation required", comment: ""))
                    .font(.headline)
            }
            Text(NSLocalizedString("Before any model can be called, deveco requires you to accept its product terms and privacy statement.", comment: ""))
                .font(.callout)
            if let terms = agreement?.termsUrl, let url = URL(string: terms) {
                Link("Read the terms", destination: url)
                    .font(.caption)
            }
            if let privacy = agreement?.privacyUrl, let url = URL(string: privacy) {
                Link("Read the privacy statement", destination: url)
                    .font(.caption)
            }
            HStack {
                Button {
                    onAccept()
                } label: {
                    if isAccepting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(NSLocalizedString("I have read and accept", comment: ""))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAccepting)
                Text(NSLocalizedString("Equivalent to `deveco auth consent --accept`.", comment: ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Theme.bannerWarning)
    }
}

/// Expandable tool call card: header with status/duration, details reveal
/// input args, full output, and errors. The output text is already decoded
/// from ToolState and just was never surfaced before.
struct TaskTraceCard: View {
    let part: Part
    /// Embedded inside a tool card: the outer card already draws the single
    /// container, so this variant must not add another border/background.
    var embedded = false
    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0
    @State private var expanded = false

    private var trace: ToolTrace { ToolTrace.parse(part.text ?? "") }

    private var headerTitle: String {
        if !trace.description.isEmpty { return trace.description }
        if !trace.prompt.isEmpty { return String(trace.prompt.prefix(60)) }
        return NSLocalizedString("Task", comment: "")
    }

    private var hasDetail: Bool {
        !trace.prompt.isEmpty || !trace.result.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: hasDetail && expanded ? 8 : 0) {
            Button {
                guard hasDetail else { return }
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 20)
                    Text(headerTitle)
                        .font(.system(size: ChatTypography.meta(chatFontSize), weight: .semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let type = trace.subagentType {
                        Text(type)
                            .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    if hasDetail {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)

            if hasDetail && expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !trace.prompt.isEmpty {
                        traceSection(label: NSLocalizedString("Prompt", comment: ""), content: trace.prompt, tint: .accentColor)
                    }
                    if !trace.result.isEmpty {
                        traceSection(label: NSLocalizedString("Result", comment: ""), content: trace.result, tint: .green)
                    }
                }
                .padding(.bottom, 2)
            }
        }
    }

    /// Codex-style detail block: a tinted label and prose on a subtle surface,
    /// with no second stroke — nested boxes are what made the transcript busy.
    private func traceSection(label: String, content: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Rectangle().fill(tint).frame(width: 2, height: ChatTypography.micro(chatFontSize))
                Text(label)
                    .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                    .foregroundStyle(tint)
            }
            MarkdownContentView(content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct ToolCardView: View {
    let part: Part
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var server: ServerManager
    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    /// nil = follow the default policy (running tools expand, finished ones
    /// collapse); after the user toggles, their choice wins.
    @State private var userExpanded: Bool?

    private var state: ToolState? { part.state }

    private var questionTexts: Set<String> {
        guard part.tool == "question",
              let input = state?.input,
              let questions = toolQuestions(input) else { return [] }
        return Set(questions.map(\.question))
    }

    /// A question tool can stay `running` in the transcript after the server
    /// restarts, but its in-memory pending request is gone. Treat it as
    /// expired instead of showing an endless spinner.
    private var isExpiredQuestion: Bool {
        QuestionCardState.isExpired(
            tool: part.tool,
            status: state?.status,
            questionTexts: questionTexts,
            isSending: store.isSending,
            pending: store.pendingQuestions,
            sessionID: store.selectedSessionID
        )
    }

    private var isRunning: Bool { state?.status == "running" && !isExpiredQuestion }
    private var isStopped: Bool {
        guard let error = state?.error else { return false }
        return FailureKind.classify(error) == .aborted
    }
    private var isError: Bool { state?.status == "error" && !isStopped }

    /// "The user dismissed this question" is a normal way to end a question
    /// tool; painting the card red and labeling it Error made the transcript
    /// look broken. Keep the dismiss note as neutral metadata.
    private var isQuestionDismissed: Bool {
        part.tool == "question"
            && state?.status == "error"
            && (state?.error ?? "").localizedCaseInsensitiveContains("dismissed")
    }

    private var isExpanded: Bool {
        if let userExpanded { return userExpanded }
        if isExpiredQuestion { return true }
        return isRunning
    }

    private var collapsibleDetail: Bool {
        if part.tool == "question" { return isExpiredQuestion }
        if let output = state?.output, !output.isEmpty, !ToolTrace.looksLikeRawTrace(output) { return true }
        if let input = state?.input, !input.isEmptyObject { return true }
        if let error = state?.error, !error.isEmpty, state?.status == "error", !isStopped { return true }
        return false
    }

    private var toolName: String {
        Theme.toolName(part.tool)
    }

    private func isFilePathKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return lowered == "filepath" || lowered == "path" || lowered.hasSuffix("path")
    }

    private func openToolPath(_ path: String) {
        let candidate = URL(fileURLWithPath: path)
        let resolved = candidate.path.hasPrefix("/")
            ? candidate
            : server.projectDirectory.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: resolved.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resolved])
    }

    private var toolTint: Color {
        isError && !isQuestionDismissed
            ? .red
            : (isStopped || isQuestionDismissed ? .secondary : Theme.toolTint(part.tool ?? ""))
    }

    private var headline: String {
        if part.tool == "question", let input = state?.input, let questions = toolQuestions(input), let first = questions.first {
            return first.question
        }
        if let title = state?.title, !title.isEmpty { return title }
        if let summary = state?.summary, !summary.isEmpty { return summary }
        if let error = state?.error, !error.isEmpty { return error }
        return toolName
    }

    /// Raw task traces currently surface in `state.output`; show the parsed
    /// task description as the single line instead of a repeated tool chip.
    private var rawTraceTitle: String? {
        guard let output = state?.output, ToolTrace.looksLikeRawTrace(output) else { return nil }
        let trace = ToolTrace.parse(output)
        return trace.description.isEmpty ? trace.prompt : trace.description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if collapsibleDetail {
                    withAnimation(.easeInOut(duration: 0.15)) { userExpanded = !isExpanded }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: Theme.toolSymbol(part.tool ?? ""))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(toolTint)
                        .frame(width: 28, height: 28)
                        .background(toolTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(toolName)
                                .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                                .foregroundStyle(toolTint)
                            Text(rawTraceTitle ?? headline)
                                .font(.system(size: ChatTypography.meta(chatFontSize), weight: .medium))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let rawTraceTitle, rawTraceTitle != toolName {
                                Text(toolName)
                                    .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                                    .foregroundStyle(toolTint)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(toolTint.opacity(0.10), in: Capsule())
                            }
                        }
                        if let summary = state?.summary, summary != headline, isExpanded {
                            Text(summary)
                                .font(.system(size: ChatTypography.meta(chatFontSize) - 1))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    if isStopped {
                        Text(NSLocalizedString("Stopped", comment: ""))
                            .font(.system(size: ChatTypography.micro(chatFontSize)))
                            .foregroundStyle(.secondary)
                    }
                    if isExpiredQuestion {
                        Text(NSLocalizedString("Expired", comment: ""))
                            .font(.system(size: ChatTypography.micro(chatFontSize)))
                            .foregroundStyle(.orange)
                    }
                    if let duration = state?.duration {
                        Text(duration)
                            .font(.system(size: ChatTypography.micro(chatFontSize), design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    if collapsibleDetail {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if isExpiredQuestion {
                    Text(NSLocalizedString("The server restarted before this question was answered. Send a new prompt to ask again.", comment: ""))
                        .font(.system(size: ChatTypography.micro(chatFontSize)))
                        .foregroundStyle(.secondary)
                }
                if let input = state?.input, !input.isEmptyObject {
                    toolInputView(input)
                }
                if let output = state?.output, !output.isEmpty {
                    if ToolTrace.looksLikeRawTrace(output) {
                        TaskTraceCard(part: Part(type: "task", text: output), embedded: true)
                    } else {
                        MarkdownContentView(content: output)
                        sectionLabel(NSLocalizedString("Copy", comment: ""), content: output)
                    }
                }
            }

            if let error = state?.error, !error.isEmpty, isError, !isQuestionDismissed {
                detailSection(
                    label: NSLocalizedString("Error", comment: ""),
                    content: error,
                    lineLimit: nil,
                    copyable: true,
                    tint: .red,
                    contentFontSize: max(11, ChatTypography.code(chatFontSize) - 2)
                )
            } else if isQuestionDismissed, let error = state?.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: ChatTypography.micro(chatFontSize)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isStopped ? Theme.subtleFill : Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isError && !isQuestionDismissed ? Color.red.opacity(0.45) : Theme.hairline)
        )
    }

    @ViewBuilder
    private func toolInputView(_ value: JSONValue) -> some View {
        let raw = value.displayText
        if ToolTrace.looksLikeRawTrace(raw) {
            TaskTraceCard(part: Part(type: "task", text: raw), embedded: true)
        } else if let questions = toolQuestions(value) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(NSLocalizedString("Input", comment: ""), content: prettyJSON(value) ?? raw)
                ForEach(questions) { question in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.header)
                            .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                            .foregroundStyle(toolTint)
                        Text(question.question)
                            .font(.system(size: ChatTypography.body(chatFontSize)))
                            .textSelection(.enabled)
                        if let details = question.details, !details.isEmpty {
                            Text(details)
                                .font(.system(size: ChatTypography.meta(chatFontSize)))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !question.options.isEmpty {
                            Text(question.options.map(\.label).joined(separator: " · "))
                                .font(.system(size: ChatTypography.meta(chatFontSize)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        } else if case .object(let object) = value {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(NSLocalizedString("Input", comment: ""), content: prettyJSON(value) ?? raw)
                ForEach(object.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(key)
                            .font(.system(size: ChatTypography.code(chatFontSize), weight: .semibold, design: .monospaced))
                            .foregroundStyle(key == "filePath" || key.hasSuffix("Path") ? Color.accentColor : .secondary)
                        Text(object[key]?.displayText ?? "")
                            .font(.system(size: ChatTypography.code(chatFontSize), design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if isFilePathKey(key), let path = object[key]?.stringValue, !path.isEmpty {
                            Button {
                                openToolPath(path)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .help(NSLocalizedString("Open in project", comment: ""))
                        }
                    }
                }
            }
        } else {
            detailSection(
                label: NSLocalizedString("Input", comment: ""),
                content: raw,
                lineLimit: 6,
                copyable: true
            )
        }
    }

    private func sectionLabel(_ label: String, content: String, labelColor: Color = .secondary) -> some View {
        HStack {
            Text(label)
                .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                .foregroundStyle(labelColor)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            } label: {
                Label(NSLocalizedString("Copy", comment: ""), systemImage: "doc.on.doc")
                    .font(.system(size: ChatTypography.micro(chatFontSize)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func detailSection(
        label: String,
        content: String,
        lineLimit: Int?,
        copyable: Bool,
        tint: Color = .secondary,
        contentFontSize: CGFloat? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if copyable {
                sectionLabel(label, content: content, labelColor: tint)
            } else {
                Text(label)
                    .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(content)
                .font(.system(
                    size: contentFontSize ?? ChatTypography.code(chatFontSize),
                    design: .monospaced
                ))
                .lineSpacing(max(1, ChatTypography.lineSpacing(chatFontSize) * 0.35))
                .foregroundStyle(tint == .red ? .red : .primary)
                .textSelection(.enabled)
                .lineLimit(lineLimit)
        }
    }

    private func prettyJSON(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8) else { return nil }
        return string
    }

    private func toolQuestions(_ value: JSONValue) -> [UserQuestionInfo]? {
        guard case .object(let object) = value,
              case .array(let raw) = object["questions"] ?? .null else { return nil }
        let decoder = JSONDecoder()
        return raw.compactMap { item in
            guard let data = try? JSONEncoder().encode(item) else { return nil }
            return try? decoder.decode(UserQuestionInfo.self, from: data)
        }
    }

}

/// Session-scoped error shown inside the conversation: a failure category
/// headline, the raw message, an actionable hint, and a Retry action.
struct InlineErrorBubble: View {
    let error: SessionStore.InlineError
    var onRetry: () -> Void
    @State private var showsDetails = false

    /// Server errors arrive as "Name: message" followed by a JS stack trace.
    /// Keep the actionable first line; the trace stays behind a disclosure.
    private var summary: String {
        humanizedErrorSummary(error.message, kind: error.kind)
    }

    private var details: String? {
        let trimmed = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > summary.count else { return nil }
        return trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: error.kind.symbolName)
                    .foregroundStyle(.red)
                Text(error.kind.label)
                    .font(.caption.weight(.semibold))
            }
            Text(summary)
                .font(.caption)
                .textSelection(.enabled)
            Text(error.kind.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let details {
                DisclosureGroup(isExpanded: $showsDetails) {
                    ScrollView(.vertical) {
                        Text(details)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                } label: {
                    Text(NSLocalizedString("Show details", comment: ""))
                        .font(.caption)
                }
            }
            HStack(spacing: 8) {
                Button(NSLocalizedString("Retry", comment: "")) { onRetry() }
                    .controlSize(.small)
                if let details {
                    Button(NSLocalizedString("Copy details", comment: "")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(details, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bannerError)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Renders a unified diff with green/red/label line coloring.
func colorizedDiff(_ patch: String) -> AttributedString {
    var result = AttributedString()
    for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
        let text = String(line)
        var segment = AttributedString(text + "\n")
        if text.hasPrefix("@@") {
            segment.foregroundColor = .blue
        } else if text.hasPrefix("+") {
            segment.foregroundColor = .green
        } else if text.hasPrefix("-") {
            segment.foregroundColor = .red
        }
        result += segment
    }
    return result
}

/// Slash-command suggestions floating above the input; click completes the
/// draft (Enter still sends — send() routes "/name args" to the command API).
/// File search popup for @-mentions; paths are relative to the project root.
struct FileMentionView: View {
    let results: [FsEntry]
    let query: String
    let selectedIndex: Int
    let onPick: (FsEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text(query.isEmpty
                     ? NSLocalizedString("Type to search files…", comment: "")
                     : NSLocalizedString("No matching files", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                    Button { onPick(entry) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.path)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.5)
                }
            }
        }
        .background(Theme.chromeFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.horizontal, 12)
    }
}

struct CommandPaletteView: View {
    let commands: [DevCommand]
    let selectedIndex: Int
    let onPick: (DevCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button { onPick(command) } label: {
                    HStack(spacing: 8) {
                        Text("/\(command.name)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        if let source = command.source {
                            Text(source)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Spacer(minLength: 8)
                        Text(command.description ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.5)
            }
        }
        .background(Theme.chromeFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.horizontal, 12)
    }
}

/// The agent asks the user something (question.asked). Supports single- and
/// multi-select options plus a free-text answer when `custom` is set.
struct QuestionBanner: View {
    @EnvironmentObject var store: SessionStore
    let request: UserQuestionRequest

    private let contentMaxWidth: CGFloat = 760

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    private var isComplete: Bool {
        request.questions.indices.allSatisfy { idx in
            let picked = store.questionDraft(for: request.id).selections[idx] ?? []
            if !picked.isEmpty { return true }
            let custom = store.questionDraft(for: request.id).customAnswers[idx] ?? ""
            return !custom.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(NSLocalizedString("Question", comment: "") + " · " + question.header)
                            .font(.system(size: ChatTypography.body(chatFontSize), weight: .semibold))
                        Spacer()
                        if index == 0 {
                            Button(NSLocalizedString("Skip", comment: "")) {
                                Task { await store.rejectQuestion(request) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                    }
                    Text(question.question)
                        .font(.system(size: ChatTypography.body(chatFontSize), weight: .medium))
                    if let details = question.details, !details.isEmpty {
                        Text(details)
                            .font(.system(size: ChatTypography.meta(chatFontSize)))
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 8) {
                        ForEach(question.options) { option in
                            optionRow(index: index, option: option, question: question)
                        }
                        if question.custom == true {
                            customField(index: index, question: question)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: ChatTypography.meta(chatFontSize)))
                    .foregroundStyle(isComplete ? .green : .secondary)
                Text(isComplete
                     ? NSLocalizedString("Ready to send", comment: "")
                     : NSLocalizedString("Select an option to continue", comment: ""))
                    .font(.system(size: ChatTypography.meta(chatFontSize)))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(NSLocalizedString("Send Answers", comment: "")) {
                    let answers = request.questions.indices.map { idx -> [String] in
                        let draft = store.questionDraft(for: request.id)
                        var picked = draft.selections[idx] ?? []
                        let custom = draft.customAnswers[idx]?.trimmingCharacters(in: .whitespaces) ?? ""
                        if !custom.isEmpty { picked.append(custom) }
                        return picked
                    }
                    Task { await store.answer(request, answers: answers) }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!isComplete)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.composerFill)
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }

    private func isSelected(_ index: Int, _ label: String) -> Bool {
        (store.questionDraft(for: request.id).selections[index] ?? []).contains(label)
    }

    private func optionRow(index: Int, option: UserQuestionOption, question: UserQuestionInfo) -> some View {
        let selected = isSelected(index, option.label)
        return Button {
            let multiple = question.multiple ?? false
            var current = store.questionDraft(for: request.id).selections[index] ?? []
            if multiple {
                if current.contains(option.label) {
                    current.removeAll { $0 == option.label }
                } else {
                    current.append(option.label)
                }
                store.updateQuestionDraft(for: request.id) { $0.selections[index] = current }
            } else {
                store.updateQuestionDraft(for: request.id) { $0.selections[index] = [option.label] }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: ChatTypography.meta(chatFontSize), weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: ChatTypography.body(chatFontSize), weight: selected ? .semibold : .regular))
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: ChatTypography.meta(chatFontSize)))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Theme.cardFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Theme.hairline, lineWidth: selected ? 2 : 1)
            }
            .shadow(color: selected ? Color.accentColor.opacity(0.18) : .clear, radius: 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func customField(index: Int, question: UserQuestionInfo) -> some View {
        HStack(spacing: 6) {
            let custom = store.questionDraft(for: request.id).customAnswers[index] ?? ""
            Image(systemName: isSelected(index, custom) ? "checkmark.circle.fill" : "pencil")
                .foregroundStyle(.secondary)
            TextField("Custom answer…", text: Binding(
                get: { store.questionDraft(for: request.id).customAnswers[index] ?? "" },
                set: { value in
                    store.updateQuestionDraft(for: request.id) { $0.customAnswers[index] = value }
                }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }
}
