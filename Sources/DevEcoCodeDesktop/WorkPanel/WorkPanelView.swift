import SwiftUI
import AppKit

enum WorkPanelTab: String, CaseIterable, Identifiable {
    case review
    case context

    var id: String { rawValue }

    var label: String {
        switch self {
        case .review: return NSLocalizedString("Review", comment: "")
        case .context: return NSLocalizedString("Context", comment: "")
        }
    }

    var symbol: String {
        switch self {
        case .review: return "doc.text.magnifyingglass"
        case .context: return "gauge.with.dots.needle.33percent"
        }
    }
}

/// Docked work panel for session artifacts. It stays closed unless the user
/// opens it explicitly, and each session keeps its own tab/selection state in
/// SessionStore so switching chats never leaks panel context.
struct WorkPanelView: View {
    @EnvironmentObject var store: SessionStore
    @Binding var isOpen: Bool

    private var sessionID: String? { store.selectedSessionID }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(WorkPanelTab.allCases) { tab in
                    Button {
                        if let sessionID {
                            store.workPanelTab = tab
                            store.workPanelOpenBySession[sessionID] = true
                        }
                        isOpen = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 11))
                            Text(tab.label)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            isOpen && store.workPanelTab == tab
                                ? Theme.chipFill
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .foregroundStyle(
                            isOpen && store.workPanelTab == tab ? .primary : .secondary
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    isOpen = false
                    if let sessionID { store.workPanelOpenBySession[sessionID] = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Close Work Panel", comment: ""))
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Theme.barFill)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            Group {
                if store.workPanelTab == .review {
                    WorkPanelReviewView()
                } else {
                    WorkPanelContextView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.sidebarFill)
        .frame(minWidth: 300, idealWidth: 380)
        .onAppear { Task { await store.loadDiff() } }
    }
}

/// Review tab. This reuses the existing diff renderer but lives in a docked
/// surface instead of a modal sheet so users can keep the conversation visible.
struct WorkPanelReviewView: View {
    @EnvironmentObject var store: SessionStore
    @State private var filterQuery = ""
    @State private var expandedFiles: Set<String> = []
    @State private var allExpanded = false

    private var filteredDiffs: [FileDiff] {
        let query = filterQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.diffs }
        return store.diffs.filter { $0.file.localizedCaseInsensitiveContains(query) }
    }

    private var totalAdditions: Int { store.diffs.reduce(0) { $0 + Int($1.additions ?? 0) } }
    private var totalDeletions: Int { store.diffs.reduce(0) { $0 + Int($1.deletions ?? 0) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("+\(totalAdditions)")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("-\(totalDeletions)")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(String(format: NSLocalizedString("Files: %lld", comment: ""), store.diffs.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Filter files", text: $filterQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                }
                Button(allExpanded ? "Collapse All" : "Expand All") {
                    withAnimation(.easeInOut(duration: 0.15)) { setAllExpanded(!allExpanded) }
                }
                .controlSize(.small)
                .disabled(store.diffs.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if store.isLoadingDiff {
                VStack {
                    ProgressView().controlSize(.regular)
                    Text(NSLocalizedString("Loading diff…", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.diffs.isEmpty {
                VStack {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("No file changes in this session.", comment: ""))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredDiffs.isEmpty {
                VStack {
                    Text(NSLocalizedString("No files match the filter.", comment: ""))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredDiffs) { diff in
                            DiffFileRow(
                                diff: diff,
                                isExpanded: allExpanded || expandedFiles.contains(diff.id)
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) { toggle(diff.id) }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onChange(of: store.selectedSessionID) { _ in
            filterQuery = ""
            expandedFiles = []
            allExpanded = false
            Task { await store.loadDiff() }
        }
    }

    private func setAllExpanded(_ value: Bool) {
        allExpanded = value
        expandedFiles = value ? Set(store.diffs.map(\.id)) : []
    }

    private func toggle(_ id: String) {
        let isCurrentlyExpanded = allExpanded || expandedFiles.contains(id)
        if isCurrentlyExpanded {
            if allExpanded {
                expandedFiles = Set(store.diffs.map(\.id))
                expandedFiles.remove(id)
                allExpanded = false
            } else {
                expandedFiles.remove(id)
            }
        } else {
            expandedFiles.insert(id)
        }
    }
}

/// First cut of a context inspector. It uses only data already present in the
/// selected session; no new server endpoints are introduced.
struct WorkPanelContextView: View {
    @EnvironmentObject var store: SessionStore

    private var tokenText: String {
        guard let tokens = store.selectedSession?.tokens else {
            return NSLocalizedString("No token usage yet.", comment: "")
        }
        return String(
            format: NSLocalizedString("Input %lld · Output %lld", comment: ""),
            Int(tokens.input ?? 0),
            Int(tokens.output ?? 0)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("Context", comment: ""))
                .font(.headline)
            infoRow(label: NSLocalizedString("Tokens", comment: ""), value: tokenText)
            infoRow(
                label: NSLocalizedString("Messages", comment: ""),
                value: "\(store.messages.count)"
            )
            infoRow(
                label: NSLocalizedString("File changes", comment: ""),
                value: "\(store.diffs.count)"
            )
            if let branch = store.vcsBranch, !branch.isEmpty {
                infoRow(label: NSLocalizedString("Branch", comment: ""), value: branch)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.system(size: 13))
    }
}
