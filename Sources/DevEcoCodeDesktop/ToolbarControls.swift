import SwiftUI

struct IconTooltip: ViewModifier {
    let text: String
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.1)) {
                    isHovered = inside
                }
            }
            .overlay(alignment: .bottom) {
                if isHovered {
                    Text(text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Theme.hairline, lineWidth: 1)
                        )
                        .shadow(radius: 2, y: 1)
                        .fixedSize()
                        .offset(y: 24)
                        .zIndex(100)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func iconTooltip(_ text: String) -> some View {
        modifier(IconTooltip(text: text))
    }
}

/// Top-level destinations. Named `AppSection` so it never collides with
/// SwiftUI's `Section` inside list builders.
enum AppSection: String, CaseIterable, Identifiable {
    case sessions, providers

    var id: String { rawValue }

    var navigationLabel: String {
        switch self {
        case .sessions: return NSLocalizedString("Chats", comment: "")
        case .providers: return NSLocalizedString("Models & Providers", comment: "")
        }
    }

    var icon: String {
        switch self {
        case .sessions: return "bubble.left.and.bubble.right"
        case .providers: return "server.rack"
        }
    }
}

/// Two-icon destination switcher. It lives in each pane's own top row instead
/// of a full-width band, so the window chrome stays seamless like Codex.
struct SectionSwitcher: View {
    @Binding var selection: AppSection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSection.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        selection = item
                    }
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection == item ? .primary : .secondary)
                        .frame(width: 28, height: 24)
                        .background(
                            selection == item ? Theme.chipFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.navigationLabel))
                .iconTooltip(item.navigationLabel)
            }
        }
        .padding(2)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Small connection light for the sidebar's top row. The full state text
/// stays in the tooltip so the row never crowds the window controls.
struct ServerStatusDot: View {
    @EnvironmentObject var server: ServerManager

    private var color: Color {
        switch server.state {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .gray
        }
    }

    private var text: String {
        let endpoint = "127.0.0.1:\(server.port)"
        switch server.state {
        case .running: return String(format: NSLocalizedString("Connected · %@", comment: ""), endpoint)
        case .starting: return String(format: NSLocalizedString("Starting · %@", comment: ""), endpoint)
        case .failed: return NSLocalizedString("Failed", comment: "")
        case .stopped: return NSLocalizedString("Stopped", comment: "")
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .padding(.horizontal, 3)
            .accessibilityLabel(Text(text))
            .iconTooltip(text)
    }
}

/// App-level controls shared by the sidebar and the Models pane: project
/// chooser, server start/stop, and settings.
struct AppChromeControls: View {
    @EnvironmentObject var server: ServerManager

    var body: some View {
        HStack(spacing: 2) {
            toolbarButton(
                "sidebar.left",
                help: NSLocalizedString("Toggle Sidebar (⌘B)", comment: "")
            ) {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            }

            Menu {
                Button(NSLocalizedString("Choose Folder…", comment: "")) { server.chooseFolder() }
                if !server.recentProjects.isEmpty {
                    Divider()
                    ForEach(server.recentProjects, id: \.path) { url in
                        Button((url.path as NSString).lastPathComponent) {
                            server.openProject(url)
                        }
                    }
                }
            } label: {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text(NSLocalizedString("Project", comment: "")))
            .iconTooltip(NSLocalizedString("Project", comment: ""))

            toolbarButton(
                server.state == .running ? "stop.circle" : "play.circle",
                help: server.state == .running
                    ? NSLocalizedString("Stop Server", comment: "")
                    : NSLocalizedString("Start Server", comment: "")
            ) {
                if server.state == .running {
                    server.stop()
                } else {
                    server.start()
                }
            }

            toolbarButton(
                "gearshape",
                help: NSLocalizedString("Settings (⌘,)", comment: "")
            ) {
                ContentView.openSettings()
            }
        }
    }
}

/// Borderless icon button used by the single app toolbar row.
@ViewBuilder
func toolbarButton(
    _ systemImage: String,
    help: String,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(help))
    .iconTooltip(help)
}

/// Transcript actions (text size, search, review, compact) rendered in the
/// app's single toolbar row so the chat area needs no header of its own.
struct TranscriptToolbarActions: View {
    let openWorkPanelTab: (WorkPanelTab) -> Void

    @EnvironmentObject private var store: SessionStore

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0
    @State private var copiedTranscript = false

    private func adjustChatFont(by delta: Double) {
        chatFontSize = min(
            ChatTypography.maxFontSize,
            max(ChatTypography.minFontSize, chatFontSize + delta)
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            // Codex keeps this corner quiet: one overflow menu instead of a
            // row of loose glyphs. ⌘F still opens search directly.
            Menu {
                Section {
                    Button {
                        NotificationCenter.default.post(name: .openConversationSearch, object: nil)
                    } label: {
                        Label(NSLocalizedString("Search in conversation (⌘F)", comment: ""), systemImage: "magnifyingglass")
                    }
                    Button {
                        openReviewPanel()
                    } label: {
                        Label(NSLocalizedString("Review file changes", comment: ""), systemImage: "rectangle.split.2x1")
                    }
                    Button {
                        Task { await copyTranscript() }
                    } label: {
                        Label(
                            copiedTranscript
                                ? NSLocalizedString("Copied transcript", comment: "")
                                : NSLocalizedString("Copy transcript as Markdown", comment: ""),
                            systemImage: copiedTranscript ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                    }
                    Button {
                        Task { await store.compact() }
                    } label: {
                        Label(
                            store.isCompacting
                                ? NSLocalizedString("Compacting…", comment: "")
                                : NSLocalizedString("Compact conversation", comment: ""),
                            systemImage: "arrow.down.right.and.arrow.up.left"
                        )
                    }
                    .disabled(store.isCompacting || store.isSending)
                    Button {
                        Task { await store.summarizeSelectedSession() }
                    } label: {
                        Label(NSLocalizedString("Summarize conversation", comment: ""), systemImage: "text.badge.checkmark")
                    }
                    .disabled(store.selectedModel == nil || store.isSending)
                    if store.selectedSession?.share?.url == nil {
                        Button {
                            Task { await store.shareSelectedSession() }
                        } label: {
                            Label(NSLocalizedString("Share session", comment: ""), systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            Task { await store.unshareSelectedSession() }
                        } label: {
                            Label(NSLocalizedString("Stop sharing", comment: ""), systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        openWorkPanel(.vcs)
                    } label: {
                        Label(NSLocalizedString("Working tree changes", comment: ""), systemImage: "source.control")
                    }
                    Button {
                        openWorkPanel(.files)
                    } label: {
                        Label(NSLocalizedString("Browse project files", comment: ""), systemImage: "folder")
                    }
                    Button {
                        openWorkPanel(.children)
                    } label: {
                        Label(NSLocalizedString("Child sessions", comment: ""), systemImage: "square.on.square")
                    }
                }
                Section {
                    Button {
                        adjustChatFont(by: -1)
                    } label: {
                        Label(NSLocalizedString("Smaller text", comment: ""), systemImage: "textformat.size.smaller")
                    }
                    .disabled(chatFontSize <= ChatTypography.minFontSize)
                    Button {
                        adjustChatFont(by: 1)
                    } label: {
                        Label(NSLocalizedString("Larger text", comment: ""), systemImage: "textformat.size.larger")
                    }
                    .disabled(chatFontSize >= ChatTypography.maxFontSize)
                }
                Section {
                    ForEach([13, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 30], id: \.self) { size in
                        Button {
                            chatFontSize = Double(size)
                        } label: {
                            if Int(chatFontSize) == size {
                                Label("\(size) pt", systemImage: "checkmark")
                            } else {
                                Text("\(size) pt")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(NSLocalizedString("More", comment: ""))
        }
    }

    private func openReviewPanel() {
        openWorkPanel(.review)
        Task { await store.loadDiff() }
    }

    private func openWorkPanel(_ tab: WorkPanelTab) {
        openWorkPanelTab(tab)
    }

    private func copyTranscript() async {
        guard let session = store.selectedSession else { return }
        do {
            let markdown = try await store.markdown(for: session)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            copiedTranscript = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedTranscript = false
        } catch {
            store.errorMessage = String(
                format: NSLocalizedString("Export failed: %@", comment: ""),
                UserFacingError.message(error)
            )
        }
    }
}
