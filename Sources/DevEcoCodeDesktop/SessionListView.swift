import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SessionListView: View {
    @EnvironmentObject var store: SessionStore

    @State private var query = ""
    @State private var renamingSession: Session?
    @State private var deletionCandidate: Session?
    @State private var hoveredSessionID: String?

    private var activeSessions: [Session] {
        store.sessions.filter { !$0.isArchived }
    }

    private var archivedSessions: [Session] {
        store.sessions.filter(\.isArchived)
    }

    private var matches: (Session) -> Bool {
        guard !query.isEmpty else { return { _ in true } }
        return { session in
            session.displayTitle.localizedCaseInsensitiveContains(query)
                || (session.directory ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("Chats", comment: ""))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { store.createSession() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .help("New session (⌘N)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 9)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                TextField("Search sessions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 11)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            if store.sessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                    Text("No sessions yet")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text("Create one with ⌘N")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sessionList
            }

            if let total = store.usage?.total {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                HStack {
                    Text("\(Int(total.sessions ?? 0)) sessions · \(Int(total.messages ?? 0)) messages")
                        .font(.system(size: 12))
                    Spacer()
                    if let cost = total.cost, cost > 0 {
                        Text(String(format: "$%.2f", cost))
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .background(Theme.sidebarFill)
        .sheet(item: $renamingSession) { session in
            RenameSessionView(
                initialTitle: session.displayTitle,
                onCancel: { renamingSession = nil },
                onSave: { newTitle in
                    renamingSession = nil
                    Task { await store.rename(session, to: newTitle) }
                }
            )
        }
        .confirmationDialog(
            deletionCandidate.map {
                String(format: NSLocalizedString("Delete “%@”? The conversation will be removed from the server.", comment: ""), $0.displayTitle)
            } ?? "",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { session in
            Button("Delete", role: .destructive) {
                Task { await store.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    if query.isEmpty {
                        ForEach(timeGroups(activeSessions.filter(matches)), id: \.label) { group in
                            Section {
                                ForEach(group.items) { session in
                                    row(for: session)
                                }
                            } header: {
                                sectionHeader(group.label)
                            }
                        }
                        if !archivedSessions.filter(matches).isEmpty {
                            Section {
                                ForEach(archivedSessions.filter(matches)) { session in
                                    row(for: session)
                                }
                            } header: {
                                sectionHeader(NSLocalizedString("Archived", comment: ""))
                            }
                        }
                    } else {
                        let results = store.sessions.filter(matches).sorted(by: byUpdatedDescending)
                        Section {
                            ForEach(results) { session in
                                row(for: session)
                            }
                            if results.isEmpty {
                                Text("No sessions match “\(query)”")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                            }
                        } header: {
                            sectionHeader(NSLocalizedString("Results", comment: ""))
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: store.selectedSessionID) { id in
                if let id {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .background(Theme.sidebarFill)
    }

    private func row(for session: Session) -> some View {
        let selected = session.id == store.selectedSessionID
        let hovered = hoveredSessionID == session.id
        return Button {
            store.select(session.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(session.displayTitle)
                            .font(.system(size: 14, weight: selected ? .semibold : .medium))
                            .foregroundStyle(.primary.opacity(selected ? 1 : 0.88))
                            .lineLimit(1)
                        if session.isSubagent {
                            Text("subagent")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        if session.isArchived {
                            Image(systemName: "archivebox")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        if let indicator = store.indicator(for: session.id) {
                            SessionIndicatorBadge(indicator: indicator)
                        }
                    }
                    if let directory = session.directory {
                        Text((directory as NSString).lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let updated = session.updatedAt {
                    Text(updated, format: .relative(presentation: .named))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                selected
                    ? Color.primary.opacity(0.09)
                    : (hovered ? Theme.hoverFill : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredSessionID = session.id
            } else if hoveredSessionID == session.id {
                hoveredSessionID = nil
            }
        }
        .id(session.id)
        .contextMenu {
            Button("Rename…") { renamingSession = session }
            Button("Fork") {
                Task { await store.fork(session) }
            }
            Button(session.isArchived
                   ? NSLocalizedString("Unarchive", comment: "")
                   : NSLocalizedString("Archive", comment: "")) {
                Task { await store.setArchived(session, !session.isArchived) }
            }
            Divider()
            Button("Export as Markdown…") {
                exportPanel(for: session)
            }
            Divider()
            Button("Delete…", role: .destructive) { deletionCandidate = session }
        }
    }

    private func exportPanel(for session: Session) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.displayTitle.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await store.export(session, to: url)
            } catch {
                store.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func timeGroups(_ sessions: [Session]) -> [(label: String, items: [Session])] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)

        var groups: [String: [Session]] = [:]
        for session in sessions {
            let label: String
            if let updated = session.updatedAt {
                if updated >= startOfToday {
                    label = NSLocalizedString("Today", comment: "session group")
                } else if let startOfYesterday, updated >= startOfYesterday {
                    label = NSLocalizedString("Yesterday", comment: "session group")
                } else {
                    label = NSLocalizedString("Earlier", comment: "session group")
                }
            } else {
                label = NSLocalizedString("Earlier", comment: "session group")
            }
            groups[label, default: []].append(session)
        }

        let order = [
            NSLocalizedString("Today", comment: "session group"),
            NSLocalizedString("Yesterday", comment: "session group"),
            NSLocalizedString("Earlier", comment: "session group"),
        ]
        return order.compactMap { label in
            guard let items = groups[label], !items.isEmpty else { return nil }
            return (label, items.sorted(by: byUpdatedDescending))
        }
    }

    private func byUpdatedDescending(_ a: Session, _ b: Session) -> Bool {
        (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
    }
}

/// Compact sidebar cue for work that needs the user's attention. Priority is
/// decided by SessionStore.indicator(for:), so a permission prompt always
/// wins over a background spinner or an unread completion dot.
struct SessionIndicatorBadge: View {
    let indicator: SessionStore.SessionIndicator

    private var symbol: String {
        switch indicator.kind {
        case .permission: return "lock.shield.fill"
        case .question: return "questionmark.bubble.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .retry: return "exclamationmark.arrow.circlepath"
        case .busy: return "circle.dotted"
        case .unread: return "circle.fill"
        }
    }

    private var tint: Color {
        switch indicator.kind {
        case .permission, .retry: return .orange
        case .question: return .blue
        case .failed: return .red
        case .busy: return .secondary
        case .unread: return .accentColor
        }
    }

    private var help: String {
        switch indicator.kind {
        case .permission: return NSLocalizedString("Needs permission", comment: "")
        case .question: return NSLocalizedString("Needs an answer", comment: "")
        case .failed: return NSLocalizedString("Session failed", comment: "")
        case .retry: return NSLocalizedString("Retrying", comment: "")
        case .busy: return NSLocalizedString("Generating", comment: "")
        case .unread: return NSLocalizedString("New activity", comment: "")
        }
    }

    var body: some View {
        Group {
            if indicator.kind == .busy {
                ProgressView()
                    .controlSize(.mini)
            } else if indicator.kind == .unread {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            } else {
                HStack(spacing: 2) {
                    Image(systemName: symbol)
                        .font(.caption2)
                    if indicator.count > 1 {
                        Text("\(indicator.count)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(tint.opacity(0.12), in: Capsule())
            }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct RenameSessionView: View {
    let initialTitle: String
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var title: String
    @FocusState private var titleFocused: Bool

    init(initialTitle: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.initialTitle = initialTitle
        self.onCancel = onCancel
        self.onSave = onSave
        let isUntitled = initialTitle == "Untitled session"
            || initialTitle == NSLocalizedString("New session", comment: "")
        _title = State(initialValue: isUntitled ? "" : initialTitle)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Rename Session")
                .font(.headline)
            TextField("Session title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { titleFocused = true }
    }

    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}
