import SwiftUI

/// Structure-only helpers for permission cards. Kept separate from SwiftUI so
/// risk/pattern presentation can be unit-tested without launching the app.
enum PermissionPresentation {
    struct Details {
        let tool: String
        let kind: String
        let risk: String
        let symbol: String
        let tint: Color
        let arguments: [String]
        let workspace: String?

        var argumentPreview: String {
            arguments
                .map { ServerManager.redact($0) }
                .joined(separator: "\n")
        }
    }

    static func details(for request: PermissionRequest, workspace: String?) -> Details {
        let raw = (request.action ?? request.permission ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = raw.lowercased()
        let tool = raw.isEmpty
            ? NSLocalizedString("Tool", comment: "")
            : raw.capitalized

        let risk: String
        let symbol: String
        let tint: Color
        switch lowered {
        case "bash", "command", "shell", "exec":
            risk = NSLocalizedString("High risk · runs a local command", comment: "")
            symbol = "terminal"
            tint = .orange
        case "write", "edit", "patch", "apply_patch":
            risk = NSLocalizedString("Medium risk · changes project files", comment: "")
            symbol = "pencil.line"
            tint = .yellow
        case "network", "fetch", "http":
            risk = NSLocalizedString("Medium risk · sends data to a remote endpoint", comment: "")
            symbol = "network"
            tint = .blue
        default:
            risk = NSLocalizedString("Review the arguments before allowing", comment: "")
            symbol = "lock.shield"
            tint = .orange
        }

        return Details(
            tool: tool,
            kind: raw,
            risk: risk,
            symbol: symbol,
            tint: tint,
            arguments: request.patterns ?? [],
            workspace: workspace
        )
    }
}

/// Inline permission card shown in the originating session's transcript.
struct PermissionCardView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var server: ServerManager
    let request: PermissionRequest
    var pendingCount: Int = 1

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    private var details: PermissionPresentation.Details {
        PermissionPresentation.details(
            for: request,
            workspace: server.projectDirectory.path
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: details.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(details.tint)
                    .frame(width: 22, height: 22)
                    .background(details.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(NSLocalizedString("Permission required", comment: ""))
                            .font(.system(size: ChatTypography.meta(chatFontSize), weight: .semibold))
                            .fixedSize()
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(details.tool)
                            .font(.system(size: ChatTypography.meta(chatFontSize)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if pendingCount > 1 {
                            Text(String(
                                format: NSLocalizedString("+%d waiting", comment: ""),
                                pendingCount - 1
                            ))
                            .font(.system(size: ChatTypography.micro(chatFontSize)))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                        }
                    }
                    Text(details.risk)
                        .font(.system(size: ChatTypography.micro(chatFontSize)))
                        .foregroundStyle(details.tint)
                }
                Spacer(minLength: 8)
            }

            if !details.argumentPreview.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("Arguments", comment: ""))
                        .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(details.argumentPreview)
                        .font(.system(size: ChatTypography.micro(chatFontSize), design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 6))
            }

            if let workspace = details.workspace, !workspace.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: ChatTypography.micro(chatFontSize)))
                    Text(workspace)
                        .font(.system(size: ChatTypography.micro(chatFontSize), design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Button(NSLocalizedString("Allow once", comment: "")) {
                    store.reply(to: request, reply: "once")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(NSLocalizedString("Allow for session", comment: "")) {
                    store.reply(to: request, reply: "always")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(NSLocalizedString("Deny", comment: ""), role: .destructive) {
                    store.reply(to: request, reply: "reject")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Theme.chromeFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.softStroke))
    }
}
