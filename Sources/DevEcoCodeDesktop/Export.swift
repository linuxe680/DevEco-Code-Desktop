import Foundation

/// Builds a Markdown transcript from the session's messages. Pure function so
/// it is unit-testable; the caller writes the result to disk.
enum TranscriptExporter {
    static func markdown(session: Session, messages: [MessageRecord], exportedAt: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("# \(headingText(session.displayTitle))")
        lines.append("")
        if let directory = session.directory {
            lines.append("- Project: \(inlineCode((directory as NSString).lastPathComponent))")
        }
        if let model = firstModel(messages) {
            lines.append("- Model: \(inlineCode(model))")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale.current
        lines.append("- \(NSLocalizedString("Exported", comment: "export header")): \(formatter.string(from: exportedAt))")
        lines.append("")

        for message in messages {
            lines.append("---")
            lines.append("")
            let isUser = message.info.role == "user"
            let role = isUser
                ? NSLocalizedString("You", comment: "message role")
                : "DevEco"
            lines.append("## \(headingText(role))\(metaSuffix(message.info))")
            lines.append("")
            for part in message.parts {
                appendPart(part, escapePlainText: isUser, to: &lines)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func firstModel(_ messages: [MessageRecord]) -> String? {
        messages
            .compactMap { record -> String? in
                guard let provider = record.info.providerID, let model = record.info.modelID else { return nil }
                return "\(provider)/\(model)"
            }
            .first
    }

    private static func metaSuffix(_ info: MessageInfo) -> String {
        var pieces: [String] = []
        if let created = info.time?.created {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            pieces.append(formatter.string(from: Date(timeIntervalSince1970: created / 1000)))
        }
        if let cost = info.cost, cost > 0 {
            pieces.append(String(format: "$%.4f", cost))
        }
        return pieces.isEmpty ? "" : " (\(pieces.joined(separator: ", ")))"
    }

    private static func headingText(_ text: String) -> String {
        let singleLine = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        return escapeMarkdown(singleLine)
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        for marker in ["`", "*", "_", "[", "]", "#", "<", ">"] {
            escaped = escaped.replacingOccurrences(of: marker, with: "\\\(marker)")
        }
        return escaped
    }

    private static func inlineCode(_ text: String) -> String {
        var longestRun = 0
        var run = 0
        for character in text {
            if character == "`" { run += 1; longestRun = max(longestRun, run) } else { run = 0 }
        }
        let delimiter = String(repeating: "`", count: max(1, longestRun + 1))
        return "\(delimiter)\(text)\(delimiter)"
    }

    private static func appendPart(
        _ part: Part,
        escapePlainText: Bool,
        to lines: inout [String]
    ) {
        switch part.type {
        case "text":
            if let text = part.text, !text.isEmpty {
                lines.append(escapePlainText ? escapeMarkdown(text) : text)
                lines.append("")
            }
        case "reasoning":
            if let text = part.text, !text.isEmpty {
                lines.append("<details><summary>\(NSLocalizedString("Thinking", comment: "export section"))</summary>")
                lines.append("")
                lines.append(text)
                lines.append("")
                lines.append("</details>")
                lines.append("")
            }
        case "tool":
            let status = part.state?.summary ?? ""
            let title = part.state?.title.map { " — \($0)" } ?? ""
            lines.append("> 🔨 **\(escapeMarkdown(Theme.toolName(part.tool)))** \(escapeMarkdown(status))\(escapeMarkdown(title))")
            lines.append("")
        default:
            break
        }
    }
}
