import SwiftUI
import AppKit

/// Compact Codex-style timeline: a thin rail with one tick per message and a
/// draggable thumb. It lets long sessions be scrubbed without rendering every
/// message in a separate virtualized list.
struct TranscriptOverview: View {
    let messageCount: Int
    let progress: CGFloat
    let onScrub: (CGFloat) -> Void

    @State private var dragProgress: CGFloat?

    private var value: CGFloat { dragProgress ?? progress }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 3)

                if messageCount > 1 {
                    ForEach(0..<messageCount, id: \.self) { index in
                        Capsule()
                            .fill(index == lastMatchIndex ? Color.accentColor : Color.secondary.opacity(0.45))
                            .frame(width: index == lastMatchIndex ? 7 : 5, height: 1)
                            .offset(x: index == lastMatchIndex ? -2 : -1,
                                    y: height * CGFloat(index) / CGFloat(max(1, messageCount - 1)))
                    }
                }

                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 5, height: 30)
                    .offset(y: max(0, min(height - 30, height * value)))
            }
            .frame(width: 12, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let next = max(0, min(1, gesture.location.y / max(1, height - 30)))
                        dragProgress = next
                        onScrub(next)
                    }
                    .onEnded { _ in dragProgress = nil }
            )
        }
        .frame(width: 12)
        .help(NSLocalizedString("Conversation overview", comment: ""))
    }

    private var lastMatchIndex: Int {
        Int((value * CGFloat(max(0, messageCount - 1))).rounded())
    }
}

/// Reports normalized scroll offset from the enclosing NSScrollView.
struct ScrollProgressTracker: NSViewRepresentable {
    var onProgress: (CGFloat) -> Void

    func makeNSView(context: Context) -> ProgressTrackerView {
        let view = ProgressTrackerView()
        view.onProgress = onProgress
        return view
    }

    func updateNSView(_ view: ProgressTrackerView, context: Context) {
        view.onProgress = onProgress
        view.report()
    }

    final class ProgressTrackerView: NSView {
        var onProgress: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            guard window != nil, let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.report() })
            observers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: scroll.documentView, queue: .main
            ) { [weak self] _ in self?.report() })
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        func report() {
            guard let scroll = enclosingScrollView,
                  let document = scroll.documentView,
                  let onProgress else { return }
            let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let progress = maxY <= 0 ? 1 : min(1, max(0, scroll.contentView.bounds.origin.y / maxY))
            onProgress(progress)
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

/// Tracks whether the conversation sits near the bottom of the scroll view.
/// SwiftUI's ScrollView is NSScrollView-backed on macOS, so the tracker sits
/// as a background of the scrolled content and observes the enclosing clip
/// view's bounds changes directly — reliable even with a lazy stack whose
/// tail views are virtualized away.
struct ScrollTracker: NSViewRepresentable {
    /// (nearBottom, contentFitsViewport)
    var onNearBottom: (Bool, Bool) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onNearBottom = onNearBottom
        return view
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onNearBottom = onNearBottom
        view.report()
    }

    final class TrackerView: NSView {
        var onNearBottom: ((Bool, Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private static let threshold: CGFloat = 80
        private var lastContentHeight: CGFloat = 0
        /// Whether the transcript was pinned to the tail before the current
        /// layout pass. Content growth (streamed text, a footer that appears
        /// after usage lands) must not be mistaken for the user scrolling up.
        private var wasNearBottom = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            guard window != nil, let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.report() })
            observers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: scroll.documentView, queue: .main
            ) { [weak self] _ in self?.report() })
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        func report() {
            guard let scroll = enclosingScrollView,
                  let document = scroll.documentView,
                  let onNearBottom else { return }
            let clip = scroll.contentView.bounds
            let distance = document.bounds.height - clip.origin.y - clip.height
            let fits = document.bounds.height <= clip.height + 1
            let grew = document.bounds.height > lastContentHeight + 0.5
            lastContentHeight = document.bounds.height
            var near = distance <= Self.threshold || fits
            // Keep following the tail while the transcript grows. Without this
            // the final footer (rendered a beat after the last delta) pushes
            // the content down and leaves the reply clipped by the composer.
            if grew, wasNearBottom, !fits, NSEvent.pressedMouseButtons == 0 {
                let target = max(0, document.bounds.height - clip.height)
                scroll.contentView.scroll(to: NSPoint(x: clip.origin.x, y: target))
                scroll.reflectScrolledClipView(scroll.contentView)
                near = true
            }
            // A previous `scrollTo(bottom:)` can leave a short transcript
            // parked a few points above its natural top, which eats the top
            // padding. With nothing to scroll, the only valid offset is zero.
            if fits, clip.origin.y != 0 {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            wasNearBottom = near
            onNearBottom(near, fits)
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}


/// Shared formatters. A fresh `DateFormatter` costs ~1 ms to build, and the
/// transcript renders one label per message at ~30 fps while streaming — the
/// allocation dominated the row cost. `DateFormatter` is not thread-safe, so
/// these are only touched from the main actor (all call sites are views).
private enum ChatDateFormatters {
    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeStyle = .short
        return formatter
    }()

    static let mediumDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

func conversationDateLabel(_ date: Date) -> String {
    let formatter = ChatDateFormatters.shortTime
    if Calendar.current.isDateInToday(date) {
        return String(format: NSLocalizedString("Today %@", comment: "date divider"), formatter.string(from: date))
    }
    if Calendar.current.isDateInYesterday(date) {
        return String(format: NSLocalizedString("Yesterday %@", comment: "date divider"), formatter.string(from: date))
    }
    return ChatDateFormatters.mediumDate.string(from: date)
}

func messageTimeLabel(_ date: Date) -> String {
    ChatDateFormatters.shortTime.string(from: date)
}

struct TimelineDivider: View {
    let text: String
    var symbol: String? = nil

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: ChatTypography.micro(chatFontSize)))
                    .foregroundStyle(.tertiary)
            }
            Text(text)
                .font(.system(size: ChatTypography.micro(chatFontSize), weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
