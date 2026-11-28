import SwiftUI
import AppKit

/// Slim sticky bar above the transcript, visible while the agent works even
/// when the user has scrolled away from the tail: current tool, todo
/// progress, and retry state in one line.
struct ActivityBar: View {
    let tool: Part?
    let todoProgress: String?
    let retryInfo: String?
    /// The agent is model-generating when no tool is executing.
    var isThinking: Bool = false
    /// True when a run is active but no delta arrived for over a minute.
    var stalled: Bool = false
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            if let tool {
                Image(systemName: "hammer")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Text(Theme.toolName(tool.tool))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            } else if isThinking {
                Image(systemName: "brain")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.blue)
                Text(NSLocalizedString("Thinking…", comment: "model is generating"))
                    .font(.system(size: 14, weight: .semibold))
            } else {
                Text(NSLocalizedString("Working…", comment: ""))
                    .font(.system(size: 14, weight: .semibold))
            }
            if let todoProgress {
                Label(todoProgress, systemImage: "checklist")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let retryInfo, !retryInfo.isEmpty {
                Label(retryInfo, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if stalled {
                Text(NSLocalizedString("No output for over a minute — press Esc to stop.", comment: ""))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Stop generating", comment: ""))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.chromeFill)
    }
}

struct StarterPromptButton: View {
    let systemImage: String
    let title: String
    let detail: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12))
                    .foregroundStyle(hovered ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Color.accentColor.opacity(0.07) : Theme.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(hovered ? Color.accentColor.opacity(0.28) : Theme.softStroke)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Multiline input backed by NSTextView so Enter can send and Shift+Enter can
/// insert a newline (a no-modifier keyboardShortcut on a Button is inert on
/// macOS, and TextEditor swallows Return).
struct ChatInput: NSViewRepresentable {
    @Binding var text: String
    var enterSends: Bool
    var fontSize: Double
    var focusTrigger: Int
    var draftToken: UUID
    var placeholder: String
    var onHistoryUp: () -> Void
    var onHistoryDown: () -> Void
    var onArrowUp: () -> Bool
    var onArrowDown: () -> Bool
    var onTab: () -> Bool
    var onReturn: () -> Bool
    var onPasteImage: (Data) -> Void
    var onPasteFileURLs: ([URL]) -> Void
    var onDragHover: (Bool) -> Void
    var onEscape: () -> Void
    var onContentHeight: (CGFloat) -> Void
    var onSend: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: ((String) -> Void)?
        var onSend: (() -> Void)?
        /// Token of the binding value last installed into the text view.
        /// A changed token means code replaced the draft (send / switch /
        /// history / edit), while an unchanged token with a different string
        /// is only a stale render of the user's own keystrokes.
        var lastSyncedToken: UUID?
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange?(textView.string)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = ChatTextView.make(
            frame: NSRect(x: 0, y: 0, width: 480, height: 52)
        )
        textView.string = text
        coordinator.lastSyncedToken = draftToken
        textView.isRichText = false
        textView.placeholder = placeholder
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: ChatTypography.body(fontSize))
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 480,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 52)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = coordinator
        textView.onSend = {
            textView.isSendInFlight = true
            coordinator.onSend?()
        }
        textView.onContentHeight = onContentHeight
        textView.onPasteImage = onPasteImage
        textView.onPasteFileURLs = onPasteFileURLs
        textView.onDragHover = onDragHover

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        DispatchQueue.main.async { [weak textView] in
            if let textView { textView.reportHeight() }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTextChange = { text = $0 }
        coordinator.onSend = onSend
        guard let textView = scroll.documentView as? ChatTextView else { return }
        // Keep the drawing-only placeholder in sync. Never assign to
        // `textView.string` here: that mutates the text storage, fires
        // textDidChange, and can feed "Write a message…" back into the draft.
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
        }
        let width = max(scroll.contentSize.width, 1)
        if abs(textView.frame.width - width) > 0.5 {
            var frame = textView.frame
            frame.size.width = width
            textView.frame = frame
            textView.textContainer?.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        textView.enterSends = enterSends
        let resolvedFont = NSFont.systemFont(
            ofSize: ChatTypography.body(fontSize)
        )
        if textView.font != resolvedFont {
            textView.font = resolvedFont
            DispatchQueue.main.async { [weak textView] in
                textView?.reportHeight()
            }
        }
        textView.onHistoryUp = onHistoryUp
        textView.onHistoryDown = onHistoryDown
        textView.onArrowUp = onArrowUp
        textView.onArrowDown = onArrowDown
        textView.onTab = onTab
        textView.onReturn = onReturn
        textView.onEscape = onEscape
        textView.onDragHover = onDragHover
        textView.onContentHeight = onContentHeight
        if textView.lastFocusTrigger != focusTrigger {
            textView.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async { [weak textView] in
                textView?.window?.makeFirstResponder(textView)
            }
        }
        if textView.string != text {
            // Code-driven replacement (send / switch / history / edit) always
            // wins — including the clear after send. If the token is the same
            // the difference is just a stale render of user typing, which we
            // never overwrite mid-keystroke or during IME composition.
            if !textView.hasMarkedText() {
                if coordinator.lastSyncedToken != draftToken {
                    textView.string = text
                    coordinator.lastSyncedToken = draftToken
                    textView.isSendInFlight = false
                } else {
                    // The binding caught up to the user's own typing. Keep
                    // the token in sync without touching the text storage.
                    coordinator.lastSyncedToken = draftToken
                }
            }
            // Report outside the view update — mutating state here would be
            // discarded by SwiftUI.
            DispatchQueue.main.async { [weak textView] in
                textView?.reportHeight()
            }
        }
    }
}

private final class ChatTextView: NSTextView {
    var onSend: (() -> Void)?
    var onHistoryUp: (() -> Void)?
    var onHistoryDown: (() -> Void)?
    var onArrowUp: (() -> Bool)?
    var onArrowDown: (() -> Bool)?
    var onTab: (() -> Bool)?
    var onReturn: (() -> Bool)?
    var onPasteImage: ((Data) -> Void)?
    var onPasteFileURLs: (([URL]) -> Void)?
    var onDragHover: ((Bool) -> Void)?
    var onEscape: (() -> Void)?
    var onContentHeight: ((CGFloat) -> Void)?
        var placeholder = ""
    var enterSends = true
    var lastFocusTrigger = -1
    /// Set while a send is in flight. Enter during this window would
    /// otherwise flush text typed after send() cleared the draft — the race
    /// that merged two messages into one. Cleared on the next text change.
    var isSendInFlight = false

    /// `init(frame:textContainer:)` does not build a text system when the
    /// container is nil; create storage + layout manager + container here.
    static func make(frame: NSRect) -> ChatTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        return ChatTextView(frame: frame, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .string])
    }

    override func insertNewline(_ sender: Any?) {
        // Let the input method finish composition (e.g. Chinese IME
        // candidates); intercepting that Enter would send mid-word.
        if hasMarkedText() {
            super.insertNewline(sender)
            return
        }
        // A send just cleared the composer; any text on screen now was typed
        // after that send and must not be flushed by the same Enter press.
        if isSendInFlight && !string.isEmpty {
            isSendInFlight = false
            return
        }
        let hasShift = NSApp.currentEvent?.modifierFlags.contains(.shift)
            ?? NSApplication.shared.currentEvent?.modifierFlags.contains(.shift)
            ?? false
        if enterSends && !hasShift {
            // A visible candidate list wins: Enter completes, a second Enter
            // (popup now closed) sends.
            if onReturn?() != true {
                onSend?()
            }
        } else {
            super.insertNewline(sender)
        }
    }

    func reportHeight() {
        guard let onContentHeight, let layoutManager, let textContainer else { return }
        let used = layoutManager.usedRect(for: textContainer).height
        let total = used + textContainerInset.height * 2 + 6
        let height = max(52, min(160, ceil(total)))
        if abs(frame.height - height) > 0.5 {
            var next = frame
            next.size.height = height
            frame = next
        }
        onContentHeight(height)
    }

    override func didChangeText() {
        super.didChangeText()
        isSendInFlight = false
        reportHeight()
    }

    /// Placeholder drawn inside the view so it hides while IME marked text
    /// (composition) is on screen — a SwiftUI overlay cannot observe that.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        NSAttributedString(string: placeholder, attributes: attributes).draw(
            at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height - 3)
        )
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        // Screenshot tools and copied images land here.
        if let image = NSImage(pasteboard: board),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            onPasteImage?(png)
            return
        }
        // Files copied in Finder attach by reference.
        if let urls = board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onPasteFileURLs?(urls)
            return
        }
        super.paste(sender)
    }

    // Drag files onto the input to attach them (same channel as paste).
    // The hover callbacks drive the composer's accent-border highlight.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(.fileURL) == true {
            onDragHover?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragHover?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragHover?(false)
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHover?(false)
        if let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            onPasteFileURLs?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
        // A marked-text session means an IME candidate window is open. Esc
        // must close the candidates (not abort the run), and arrow keys must
        // move the candidate selection instead of recalling prompt history.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        let hasOption = event.modifierFlags.contains(.option)
        let isUp = event.specialKey == .upArrow || event.keyCode == 126
        let isDown = event.specialKey == .downArrow || event.keyCode == 125
        let isTab = event.specialKey == .tab || event.keyCode == 48
        if hasOption && isUp {
            onHistoryUp?()
            return
        }
        if hasOption && isDown {
            onHistoryDown?()
            return
        }
        if isUp, let up = onArrowUp, up() { return }
        if isDown, let down = onArrowDown, down() { return }
        if isTab, let tab = onTab, tab() { return }
        if event.keyCode == 53, let onEscape { onEscape(); return } // Escape 不在 SpecialKey 中
        super.keyDown(with: event)
    }
}
