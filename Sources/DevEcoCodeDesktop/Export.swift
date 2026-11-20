import Foundation

/// Builds a Markdown transcript from the session's messages. Pure function so
/// it is unit-testable; the caller writes the result to disk.
enum TranscriptExporter {
    static func markdown(session: Session, messages: [MessageRecord], exportedAt: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("# \(session.displayTitle)")
        lines.append("")
        if let directory = session.directory {
            lines.append("- Project: `\((directory as NSString).lastPathComponent)`")
        }
        if let model = firstModel(messages) {
            lines.append("- Model: `\(model)`")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("- Exported: \(formatter.string(from: exportedAt))")
        lines.append("")

        for message in messages {
            lines.append("---")
            lines.append("")
            lines.append("## \(message.info.role == "user" ? "You" : "DevEco")\(metaSuffix(message.info))")
            lines.append("")
            for part in message.parts {
                appendPart(part, to: &lines)
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

    private static func appendPart(_ part: Part, to lines: inout [String]) {
        switch part.type {
        case "text":
            if let text = part.text, !text.isEmpty {
                lines.append(text)
                lines.append("")
            }
        case "reasoning":
            if let text = part.text, !text.isEmpty {
                lines.append("<details><summary>Thinking</summary>")
                lines.append("")
                lines.append(text)
                lines.append("")
                lines.append("</details>")
                lines.append("")
            }
        case "tool":
            let status = part.state?.summary ?? ""
            let title = part.state?.title.map { " — \($0)" } ?? ""
            lines.append("> 🔨 **\(Theme.toolName(part.tool))** \(status)\(title)")
            lines.append("")
        default:
            break
        }
    }
}
