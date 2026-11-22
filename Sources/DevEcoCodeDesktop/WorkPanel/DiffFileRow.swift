import SwiftUI

/// One file's unified diff in the docked Review panel.
struct DiffFileRow: View {
    let diff: FileDiff
    let isExpanded: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onToggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .font(.caption.weight(.bold))
                    Text((diff.file as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("+\(Int(diff.additions ?? 0))")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("-\(Int(diff.deletions ?? 0))")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)
            .help(diff.file)

            if isExpanded, let patch = diff.patch, !patch.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(colorizedDiff(patch))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(10)
                }
                .frame(maxHeight: 320)
            }
        }
        .background(Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.softStroke)
        )
    }

    private var statusIcon: String {
        switch diff.status {
        case "added": return "A"
        case "deleted": return "D"
        default: return "M"
        }
    }

    private var statusColor: Color {
        switch diff.status {
        case "added": return .green
        case "deleted": return .red
        default: return .orange
        }
    }
}
