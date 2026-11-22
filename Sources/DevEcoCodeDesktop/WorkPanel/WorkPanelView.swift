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
                            store.setWorkPanelTab(tab)
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
                Button(NSLocalizedString(allExpanded ? "Collapse All" : "Expand All", comment: "")) {
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

/// Context inspector. The composer stays clean like Codex; token details live
/// here, split by what each number actually means:
/// - Context: the full request context of the latest turn vs. model limit.
/// - Generated: output + reasoning, i.e. what the model wrote this turn.
/// - Session totals: cumulative counters reported by the server.
struct WorkPanelContextView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var providers: ProviderStore

    private var latestAssistant: MessageRecord? {
        store.messages.last(where: { $0.info.role == "assistant" })
    }

    private var latestTokens: MessageTokens? {
        if let tokens = latestAssistant?.info.tokens, tokens.contextUsed > 0 {
            return tokens
        }
        return store.messages.reversed()
            .first(where: { $0.info.role == "assistant" && ($0.info.tokens?.contextUsed ?? 0) > 0 })?
            .info.tokens
    }

    private var contextUsed: Double { latestTokens?.contextUsed ?? 0 }

    private var contextLimit: Double? {
        let effectiveModel = store.selectedModel
            ?? (store.serverDefaultModel.isEmpty ? nil : store.serverDefaultModel)
        return providers.contextLimit(for: effectiveModel)
    }

    private var contextRatio: Double? {
        guard let limit = contextLimit, limit > 0, contextUsed > 0 else { return nil }
        return min(max(contextUsed / limit, 0), 1)
    }

    private var contextTint: Color {
        guard let ratio = contextRatio else { return .secondary }
        if ratio > 0.85 { return .red }
        if ratio > 0.6 { return .orange }
        return .blue
    }

    private var latestGenerated: Double {
        guard let tokens = latestTokens else { return 0 }
        return (tokens.output ?? 0) + (tokens.reasoning ?? 0)
    }

    private var sessionGenerated: Double {
        guard let tokens = store.selectedSession?.tokens else { return 0 }
        return (tokens.output ?? 0) + (tokens.reasoning ?? 0)
    }

    private var sessionInput: Double {
        store.selectedSession?.tokens?.input ?? 0
    }

    private var sessionCached: Double {
        store.selectedSession?.tokens?.cache?.read ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("Context", comment: ""))
                .font(.headline)

            if contextUsed > 0 {
                contextCard
            } else {
                Text(NSLocalizedString("No token usage yet.", comment: ""))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(NSLocalizedString("Latest reply", comment: "context panel section"))
                infoRow(
                    label: NSLocalizedString("Generated", comment: "tokens generated by the model"),
                    value: compactTokenCount(latestGenerated)
                )
            }

            if sessionGenerated > 0 || sessionInput > 0 || sessionCached > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel(NSLocalizedString("This session", comment: "context panel section"))
                    infoRow(label: NSLocalizedString("Generated", comment: "tokens generated by the model"), value: compactTokenCount(sessionGenerated))
                    infoRow(label: NSLocalizedString("New input", comment: "uncached input tokens"), value: compactTokenCount(sessionInput))
                    infoRow(label: NSLocalizedString("Cached input", comment: "cached input tokens"), value: compactTokenCount(sessionCached))
                }
            }

            Divider()

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

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(NSLocalizedString("Context window", comment: "context panel label"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(contextReadout)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(contextTint)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let ratio = contextRatio {
                        Capsule()
                            .fill(contextTint)
                            .frame(width: max(3, proxy.size.width * ratio))
                    }
                }
            }
            .frame(height: 5)
            Text(NSLocalizedString(
                "Full request context of the latest turn, including history and tool output — not the size of your message.",
                comment: "context panel explanation"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var contextReadout: String {
        if let limit = contextLimit, limit > 0, let ratio = contextRatio {
            return "\(compactTokenCount(contextUsed)) / \(compactTokenCount(limit)) · \(Int((ratio * 100).rounded()))%"
        }
        return compactTokenCount(contextUsed)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
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
