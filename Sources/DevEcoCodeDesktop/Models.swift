import Foundation

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var isEmptyObject: Bool {
        if case .object(let values) = self { return values.isEmpty }
        return false
    }

    var displayText: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values): return "[" + values.map(\.displayText).joined(separator: ", ") + "]"
        case .object(let values):
            return values.map { "\($0.key): \($0.value.displayText)" }.joined(separator: ", ")
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

struct Project: Identifiable, Codable {
    let id: String
    let worktree: String
    let name: String?

    var displayName: String { name ?? (worktree as NSString).lastPathComponent }
}

struct SessionTime: Codable {
    let created: Double?
    let updated: Double?
    let archived: Double?
}

struct SessionModel: Codable {
    let id: String?
    let providerID: String?
    let variant: String?

    var modelID: String? {
        guard let id, !id.isEmpty else { return nil }
        if let providerID, !providerID.isEmpty, id.hasPrefix(providerID + "/") {
            return id
        }
        guard let providerID, !providerID.isEmpty else { return id }
        return "\(providerID)/\(id)"
    }
}

struct Session: Identifiable, Codable {
    let id: String
    var title: String?
    let directory: String?
    let time: SessionTime?
    let revert: SessionRevert?
    var parentID: String?
    var permission: [PermissionRule]?
    /// Model recorded by the server for this session. Older servers used a
    /// plain id string; current ones send {id, providerID, variant}.
    var model: SessionModel?
    var tokens: MessageTokens?
    var cost: Double?
    var share: SessionShareInfo?

    enum CodingKeys: String, CodingKey {
        case id, title, directory, time, revert, parentID, permission, model, tokens, cost, share
    }

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "new session" || normalized == "untitled session" {
                return NSLocalizedString("New session", comment: "")
            }
            return title
        }
        return NSLocalizedString("Untitled session", comment: "")
    }

    var updatedAt: Date? {
        guard let updated = time?.updated else { return nil }
        return Date(timeIntervalSince1970: updated / 1000)
    }

    /// The server marks archived sessions with time.archived (a timestamp);
    /// 0 means not archived, since the API cannot set the key back to null.
    var isArchived: Bool {
        (time?.archived ?? 0) > 0
    }

    var isReverted: Bool { revert?.messageID != nil }

    /// Internal sessions the agent spawned for itself: harness task children
    /// carry parentID, but the memory-extraction flow creates a top-level
    /// session whose title is the only marker.
    var isSubagent: Bool {
        if parentID != nil { return true }
        guard let title, !title.isEmpty else { return false }
        return title.hasPrefix("🧠 ")
    }
}

/// Present when the session was rolled back to an earlier message
/// (POST /session/{id}/revert); cleared by /unrevert.
struct SessionRevert: Codable {
    let messageID: String?
    let snapshot: String?
}

/// One approval rule (PATCH /session/{id} permission field).
/// Action values verified from the server schema: allow / deny / ask.
/// NOTE: the server APPENDS rules on PATCH (live-verified) — rules cannot be
/// replaced or cleared, so approval-mode switching is not implementable yet.
struct PermissionRule: Codable, Equatable {
    let permission: String
    let pattern: String
    let action: String

    enum CodingKeys: String, CodingKey {
        case permission, pattern, action
    }

    init(permission: String, pattern: String, action: String) {
        self.permission = permission
        self.pattern = pattern
        self.action = action
    }
}

/// Composer access mode, backed by real session permission rules.
///
/// The server only APPENDS rules on PATCH, but the last matching rule wins
/// (live-verified), so writing the full gated set again flips the mode
/// without needing a clear operation. Read-only tools are left untouched:
/// "ask" only re-arms the tools that can change state or leave the project.
enum SessionAccessMode: String, CaseIterable, Identifiable {
    case ask
    case allowAll

    var id: String { rawValue }

    /// Tools whose approval prompts this mode governs.
    static let gatedPermissions = [
        "edit", "bash", "external_directory", "webfetch", "websearch", "task",
    ]

    var label: String {
        switch self {
        case .ask:
            return NSLocalizedString("Ask for approval", comment: "composer access mode")
        case .allowAll:
            return NSLocalizedString("Full access", comment: "composer access mode")
        }
    }

    var shortLabel: String {
        switch self {
        case .ask:
            return NSLocalizedString("Ask", comment: "composer access mode, compact")
        case .allowAll:
            return NSLocalizedString("Full access", comment: "composer access mode, compact")
        }
    }

    var symbol: String {
        switch self {
        case .ask: return "lock.shield"
        case .allowAll: return "lock.open"
        }
    }

    var help: String {
        switch self {
        case .ask:
            return NSLocalizedString("Edits and commands wait for your approval.", comment: "access mode help")
        case .allowAll:
            return NSLocalizedString("Edits and commands run without asking. Use with care.", comment: "access mode help")
        }
    }

    /// The mode a session is currently in, read from its appended rules.
    static func current(for rules: [PermissionRule]?) -> SessionAccessMode {
        guard let last = rules?.last(where: { gatedPermissions.contains($0.permission) }) else {
            return .ask
        }
        return last.action == "allow" ? .allowAll : .ask
    }

    /// Rules to append when switching to this mode.
    var rules: [PermissionRule] {
        let action = self == .allowAll ? "allow" : "ask"
        return Self.gatedPermissions.map {
            PermissionRule(permission: $0, pattern: "*", action: action)
        }
    }
}

struct MessageRecord: Identifiable, Codable {
    var info: MessageInfo
    var parts: [Part]

    var id: String { info.id }
}

/// A slash command from GET /command. One list covers user commands, MCP
/// prompts, and skills — `source` tells them apart.
struct DevCommand: Codable, Identifiable {
    let name: String
    let description: String?
    let source: String?
    let template: String?

    var id: String { name }
}

struct CatalogProvider: Decodable, Identifiable {
    let id: String
    let name: String?
    let source: String?
    let env: [String]?
    let models: [String: JSONValue]?

    var displayName: String { name ?? id }
    var modelCount: Int { models?.count ?? 0 }
}

struct CatalogResponse: Decodable {
    let all: [CatalogProvider]
}

struct MessageInfo: Codable {
    let id: String
    let role: String
    let modelID: String?
    let providerID: String?
    let cost: Double?
    let tokens: MessageTokens?
    let time: MessageTime?
    let sessionID: String?
    let variant: String?

    enum CodingKeys: String, CodingKey {
        case id, role, cost, tokens, time, sessionID, variant
        case modelID
        case providerID
    }

    init(id: String, role: String, modelID: String? = nil, providerID: String? = nil,
         cost: Double? = nil, tokens: MessageTokens? = nil, time: MessageTime? = nil,
         sessionID: String? = nil, variant: String? = nil) {
        self.id = id
        self.role = role
        self.modelID = modelID
        self.providerID = providerID
        self.cost = cost
        self.tokens = tokens
        self.time = time
        self.sessionID = sessionID
        self.variant = variant
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        cost = try container.decodeIfPresent(Double.self, forKey: .cost)
        tokens = try container.decodeIfPresent(MessageTokens.self, forKey: .tokens)
        time = try container.decodeIfPresent(MessageTime.self, forKey: .time)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
    }

    /// Wall-clock time spent on this assistant turn.
    var elapsedMilliseconds: Double? {
        guard let created = time?.created,
              let completed = time?.completed,
              completed > created else { return nil }
        return completed - created
    }

    var elapsedDuration: String? {
        elapsedMilliseconds.map(formatChatDuration)
    }

    var createdDate: Date? {
        time?.created.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// Usage counters reported on assistant messages; all optional so partial
/// data from any server version still decodes.
struct MessageTokens: Codable {
    let total: Double?
    let input: Double?
    let output: Double?
    let reasoning: Double?
    let cache: TokenCache?

    /// Tokens the model had to read for this turn. The server's `total`
    /// includes this turn's output/reasoning, so it is a spend counter, not a
    /// context gauge — using it overstates how full the window is.
    var contextUsed: Double {
        let prompt = (input ?? 0) + (cache?.read ?? 0)
        if prompt > 0 { return prompt }
        guard let total, let output else { return total ?? 0 }
        return max(0, total - output - (reasoning ?? 0))
    }
}

struct TokenCache: Codable {
    let read: Double?
    let write: Double?
}

/// Compact token counts shared by the transcript footer, composer warning,
/// and Work Panel. Whole thousands drop the redundant ".0" (`960k`, not
/// `960.0k`) so readouts stay short.
func compactTokenCount(_ value: Double) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", value / 1_000_000)
            .replacingOccurrences(of: ".0M", with: "M")
    }
    if value >= 1_000 {
        return String(format: "%.1fk", value / 1_000)
            .replacingOccurrences(of: ".0k", with: "k")
    }
    return String(Int(value))
}

/// Millisecond epochs; assistant messages also carry `completed`.
struct MessageTime: Codable {
    let created: Double?
    let completed: Double?
}

/// Compact user-facing duration shared by messages and tool cards.
func formatChatDuration(milliseconds: Double) -> String {
    let seconds = max(0, milliseconds) / 1000
    if seconds < 0.01 {
        return NSLocalizedString("<0.01s", comment: "sub-10ms duration")
    }
    if seconds >= 60 {
        return String(
            format: NSLocalizedString("%.0fm %02.0fs", comment: "minutes and seconds"),
            seconds / 60,
            seconds.truncatingRemainder(dividingBy: 60)
        )
    }
    if seconds >= 10 {
        return String(format: NSLocalizedString("%.1fs", comment: "seconds with one decimal"), seconds)
    }
    return String(format: NSLocalizedString("%.2fs", comment: "seconds with two decimals"), seconds)
}

/// Loose identity for model ids: the server may report `workbuddy/hy4flash`
/// while the catalog calls the same model `workbuddy/hy4flash-free`.
func normalizedModelKey(_ raw: String) -> String {
    raw.lowercased().filter { $0.isLetter || $0.isNumber }
}

/// Resolve a server-reported model id against catalog ids that may carry a
/// vendor suffix (`hy4flash` vs `hy4flash-free`). Only an exact normalized id
/// or a unique match on a known suffix qualifies, so a base id never resolves
/// to its `-max` sibling.
func uniqueCatalogModelName(
    for identifier: String,
    in candidates: [(key: String, name: String)]
) -> String? {
    let key = normalizedModelKey(identifier)
    guard !key.isEmpty else { return nil }
    if let exact = candidates.first(where: { $0.key == key }) { return exact.name }
    let suffixMatches = candidates.filter { candidate in
        guard candidate.key.hasPrefix(key) else { return false }
        let remainder = candidate.key.dropFirst(key.count)
        return remainder == "free"
    }
    return suffixMatches.count == 1 ? suffixMatches[0].name : nil
}

/// Provider catalogs often include the raw model id in parentheses, e.g.
/// "Hy4 flash (hy4flash)". Drop that suffix for UI labels.
func prettyModelName(_ name: String) -> String {
    switch name {
    case "Hy4 flash (hy4flash)": return "混元 Flash"
    case "Hy4 (hy4)": return "混元"
    case "DeepSeek-V3", "deepseek-v3": return "DeepSeek V3"
    default: break
    }
    guard let open = name.range(of: " ("),
          let close = name.range(of: ")", range: open.upperBound..<name.endIndex) else {
        return name
    }
    let base = String(name[..<open.lowerBound])
    let suffix = name[close.upperBound...].trimmingCharacters(in: .whitespaces)
    guard !base.isEmpty else { return name }
    guard !suffix.isEmpty else { return base }
    return "\(base) \(suffix.hasPrefix("·") ? suffix : "· \(suffix)")"
}

/// Agent todo list item (GET /session/{id}/todo and the todo.updated event).
struct TodoItem: Codable, Identifiable, Equatable {
    let content: String
    let status: String?
    let priority: String?

    var id: String { content }

    var isDone: Bool { status == "completed" }
    var isCancelled: Bool { status == "cancelled" }
    var isInProgress: Bool { status == "in_progress" }
}

/// One file change within a session (GET /session/{id}/diff and the
/// session.diff event). `patch` is a unified diff.
struct FileDiff: Codable, Identifiable {
    let file: String
    let patch: String?
    let additions: Double?
    let deletions: Double?
    let status: String?

    var id: String { file }
}

struct Part: Identifiable, Codable {
    // Parts without a server-assigned id get a generated one at decode time.
    // A nil id would make every such part share one identity in ForEach.
    let id: String
    let type: String
    var text: String?
    let tool: String?
    let state: ToolState?
    // file parts only
    let mime: String?
    let filename: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id, type, text, tool, state, mime, filename, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        state = try container.decodeIfPresent(ToolState.self, forKey: .state)
        mime = try container.decodeIfPresent(String.self, forKey: .mime)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        url = try container.decodeIfPresent(String.self, forKey: .url)
    }

    init(id: String? = nil, type: String, text: String? = nil, tool: String? = nil, state: ToolState? = nil,
         mime: String? = nil, filename: String? = nil, url: String? = nil) {
        self.id = id ?? UUID().uuidString
        self.type = type
        self.text = text
        self.tool = tool
        self.state = state
        self.mime = mime
        self.filename = filename
        self.url = url
    }
}

struct ToolTime: Codable {
    let start: Double?
    let end: Double?
}

struct ToolState: Codable {
    /// Some server versions emit `state` as a plain status string ("running",
    /// "completed") while others emit an object. Accept both so one legacy
    /// message cannot make the whole session list fail to decode.
    enum CodingKeys: String, CodingKey {
        case status, title, output, error, input, time
    }

    let status: String?
    let title: String?
    let output: String?
    let error: String?
    let input: JSONValue?
    var time: ToolTime?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let status = try? container.decode(String.self) {
            self.status = status
            title = nil
            output = nil
            error = nil
            input = nil
            time = nil
            return
        }
        let object = try decoder.container(keyedBy: CodingKeys.self)
        status = try object.decodeIfPresent(String.self, forKey: .status)
        title = try object.decodeIfPresent(String.self, forKey: .title)
        output = try object.decodeIfPresent(String.self, forKey: .output)
        error = try object.decodeIfPresent(String.self, forKey: .error)
        input = try object.decodeIfPresent(JSONValue.self, forKey: .input)
        time = try object.decodeIfPresent(ToolTime.self, forKey: .time)
    }

    init(status: String?, title: String? = nil, output: String? = nil, error: String? = nil,
         input: JSONValue? = nil, time: ToolTime? = nil) {
        self.status = status
        self.title = title
        self.output = output
        self.error = error
        self.input = input
        self.time = time
    }

    var summary: String {
        switch status {
        case "running": return NSLocalizedString("Running", comment: "tool state")
        case "completed": return NSLocalizedString("Completed", comment: "tool state")
        case "error": return error ?? NSLocalizedString("Error", comment: "tool state")
        default: return status ?? NSLocalizedString("Tool", comment: "tool state")
        }
    }

    /// Human-readable duration between start and end, e.g. "1.2s".
    var duration: String? {
        guard let start = time?.start, let end = time?.end, end > start else { return nil }
        return formatChatDuration(milliseconds: end - start)
    }
}

/// Parses the raw transcript some harness tools emit as text (description /
/// prompt / `<task ...>` wrapper) into structured fields for rich rendering.
struct ToolTrace {
    let description: String
    let prompt: String
    let result: String
    let subagentType: String?

    private static let taskTagPattern = try? NSRegularExpression(
        pattern: "<task\\b[^>]*>",
        options: []
    )
    private static let taskEndTagPattern = try? NSRegularExpression(
        pattern: "</task>",
        options: []
    )
    private static let trailingTypePattern = try? NSRegularExpression(
        pattern: #"\n\s*subagent_type\s+[^\n]+"#,
        options: []
    )
    private static let trailingDescriptionPattern = try? NSRegularExpression(
        pattern: #",\s*subagent_type:\s*[^\n,]+,\s*description:\s*[^\n]+"#,
        options: []
    )

    static func looksLikeRawTrace(_ text: String) -> Bool {
        text.localizedStandardContains("description:")
            || text.localizedStandardContains("prompt:")
            || text.localizedStandardContains("<task")
            || text.localizedStandardContains("<task_result>")
    }

    static func parse(_ text: String) -> ToolTrace {
        var body = text
        var type: String?
        if let regex = taskTagPattern,
           let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let range = Range(match.range, in: body) {
            let tag = String(body[range])
            if let typeRange = tag.range(of: "subagent_type=\"") {
                let value = tag[typeRange.upperBound...]
                type = String(value.prefix(while: { $0 != "\"" }))
            }
            body.removeSubrange(range)
        }
        if let regex = taskEndTagPattern,
           let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let range = Range(match.range, in: body) {
            body.removeSubrange(range)
        }
        if type == nil, let regex = trailingTypePattern,
           let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let range = Range(match.range, in: body) {
            let tag = String(body[range])
            type = tag
                .replacingOccurrences(of: "subagent_type", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body.removeSubrange(range)
        }

        var description = ""
        var prompt = ""
        var result = ""
        var current = ""
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("description:") {
                description = String(trimmed.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                current = ""
            } else if trimmed.hasPrefix("prompt:") {
                prompt = String(trimmed.dropFirst("prompt:".count)).trimmingCharacters(in: .whitespaces)
                current = "prompt"
            } else if trimmed.hasPrefix("<task_result>") {
                current = "result"
                let first = String(trimmed.dropFirst("<task_result>".count))
                    .replacingOccurrences(of: "</task_result>", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !first.isEmpty { result += first + "\n" }
            } else if trimmed.hasPrefix("</task_result>") {
                current = ""
            } else {
                switch current {
                case "prompt": prompt += String(line) + "\n"
                case "result": result += String(line) + "\n"
                default: break
                }
            }
        }

        // Some task traces append `, subagent_type: ..., description: ...` at
        // the very end. Treat that description as the title when no leading
        // `description:` field was present, then strip it from the prose.
        if description.isEmpty,
           let regex = trailingDescriptionPattern,
           let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let range = Range(match.range, in: body) {
            let tag = String(body[range])
            if type == nil,
               let typeRange = tag.range(of: "subagent_type:"),
               let descriptionRange = tag.range(of: ", description:") {
                type = String(tag[typeRange.upperBound..<descriptionRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            description = tag
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "description:", with: "")
                .replacingOccurrences(of: "subagent_type:", with: "")
                .replacingOccurrences(of: type ?? "", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body.removeSubrange(range)
            if current == "prompt" {
                prompt = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if current == "result" {
                result = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return ToolTrace(
            description: description,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            result: result.trimmingCharacters(in: .whitespacesAndNewlines),
            subagentType: type
        )
    }
}

struct ModelEntry: Identifiable, Hashable {
    var id: String
    var name: String
    var reasoning: Bool
    var context: Int
    var output: Int
    var variants: [String]
}

struct ProviderEntry: Identifiable, Equatable {
    var id: String
    var name: String
    var npm: String
    var rawOptions: [String: JSONValue]
    var rawModels: [String: JSONValue]
    var models: [ModelEntry]

    var baseURL: String {
        get { rawOptions["baseURL"]?.stringValue ?? "" }
        set { rawOptions["baseURL"] = .string(newValue) }
    }

    var apiKey: String {
        get { rawOptions["apiKey"]?.stringValue ?? "" }
        set { rawOptions["apiKey"] = .string(newValue) }
    }

    static func parse(id: String, value: JSONValue) -> ProviderEntry? {
        guard let object = value.objectValue else { return nil }
        let models = object["models"]?.objectValue ?? [:]
        return ProviderEntry(
            id: id,
            name: object["name"]?.stringValue ?? id,
            npm: object["npm"]?.stringValue ?? "@ai-sdk/openai-compatible",
            rawOptions: object["options"]?.objectValue ?? [:],
            rawModels: models,
            models: models.compactMap { modelID, modelValue in
                guard let model = modelValue.objectValue else { return nil }
                let limit = model["limit"]?.objectValue ?? [:]
                return ModelEntry(
                    id: modelID,
                    name: model["name"]?.stringValue ?? modelID,
                    reasoning: model["reasoning"]?.boolValue ?? false,
                    context: limit["context"]?.intValue ?? 0,
                    output: limit["output"]?.intValue ?? 0,
                    variants: (model["variants"]?.objectValue ?? [:]).keys.sorted()
                )
            }.sorted { $0.id < $1.id }
        )
    }

    func jsonValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "npm": .string(npm),
            "options": .object(rawOptions),
        ]
        var modelObjects: [String: JSONValue] = rawModels
        for model in models {
            var modelObject = modelObjects[model.id]?.objectValue ?? [:]
            modelObject["name"] = .string(model.name)
            if model.reasoning {
                modelObject["reasoning"] = .bool(true)
            } else {
                modelObject.removeValue(forKey: "reasoning")
            }
            if model.context > 0 || model.output > 0 {
                modelObject["limit"] = .object([
                    "context": .number(Double(model.context)),
                    "output": .number(Double(model.output)),
                ])
            }
            if !model.variants.isEmpty {
                modelObject["variants"] = .object(
                    Dictionary(uniqueKeysWithValues: model.variants.map { ($0, .object([:])) })
                )
            }
            modelObjects[model.id] = .object(modelObject)
        }
        let keptIDs = Set(models.map(\.id))
        modelObjects = modelObjects.filter { keptIDs.contains($0.key) }
        object["models"] = .object(modelObjects)
        return .object(object)
    }
}

struct ModelChoice: Identifiable, Hashable {
    /// "providerID/modelID" — exactly what prompt_async's model field expects.
    let id: String
    let provider: String
    let name: String
    /// Context window in tokens; 0 when the catalog does not report one.
    var contextWindow: Int = 0
    /// Whether the model exposes reasoning-effort variants.
    var reasoning: Bool = false
}

/// One entry of GET /api/model — every model the server can run.
struct ServerModel: Codable {
    let id: String
    let name: String?
    let providerID: String?
    let limit: ModelLimit?
    let variants: [ModelVariant]?
}

/// Reasoning-effort style variants (live-verified: ids like low/medium/high/max).
struct ModelVariant: Codable {
    let id: String
}

struct ModelLimit: Codable {
    let context: Double?
    let output: Double?
}

struct ModelListResponse: Codable {
    let data: [ServerModel]?
}

/// GET /api/fs/find entry — paths are relative to the project root.
struct FsEntry: Codable, Identifiable {
    let path: String
    let type: String?
    let mime: String?

    var id: String { path }
}

struct FsFindResponse: Codable {
    let data: [FsEntry]?
}

/// UserQuestionOption/Request — the agent asks the user for a decision.
struct UserQuestionOption: Codable, Identifiable {
    let label: String
    let description: String?

    var id: String { label }
}

struct UserQuestionInfo: Codable, Identifiable {
    let question: String
    let header: String
    let options: [UserQuestionOption]
    let multiple: Bool?
    let details: String?
    let custom: Bool?

    var id: String { question }
}

/// One pending "the agent asks the user" request.
struct UserQuestionRequest: Identifiable, Decodable {
    let id: String
    let sessionID: String
    let questions: [UserQuestionInfo]
}

/// Unsubmitted answers for one question request. Keyed by request id so a
/// reused SwiftUI card can never inherit choices from a previous ask.
struct QuestionDraft {
    var selections: [Int: [String]] = [:]
    var customAnswers: [Int: String] = [:]
}

/// Decides whether a `question` tool card in the transcript is stranded:
/// the server restarted and its in-memory pending request is gone, so the
/// card would otherwise spin forever. Kept out of the view so the rule can
/// be unit-tested without a live server.
enum QuestionCardState {
    static func resultSummary(_ output: String) -> String? {
        let text = output.replacingOccurrences(of: "\\n", with: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let prefix = trimmed.range(of: "User has answered your questions:") {
            return String(trimmed[prefix.lowerBound...])
        }
        if let prefix = trimmed.range(of: "User dismissed") {
            return String(trimmed[prefix.lowerBound...])
        }
        return trimmed
    }

    static func isExpired(
        tool: String?,
        status: String?,
        questionTexts: Set<String>,
        isSending: Bool,
        pending: [UserQuestionRequest],
        sessionID: String?
    ) -> Bool {
        guard tool == "question",
              status == "running",
              !isSending,
              !questionTexts.isEmpty,
              let sessionID else { return false }
        return !pending.contains { request in
            request.sessionID == sessionID
                && !Set(request.questions.map(\.question)).isDisjoint(with: questionTexts)
        }
    }
}

// MARK: - Usage stats (GET /stats/usage)

struct UsageSummary: Codable {
    struct Total: Codable {
        let sessions: Double?
        let messages: Double?
        let cost: Double?
    }

    struct ModelUsage: Codable, Identifiable {
        let providerID: String?
        let modelID: String?
        let messages: Double?
        let cost: Double?

        var id: String { "\(providerID ?? "?")/\(modelID ?? "?")" }
    }

    let total: Total?
    let models: [ModelUsage]?
}

/// GET /vcs — branch is null outside a git repository.
struct VcsInfo: Codable {
    let branch: String?
    let defaultBranch: String?

    enum CodingKeys: String, CodingKey {
        case branch
        case defaultBranch = "default_branch"
    }
}

/// GET /global/product-agreement — deveco blocks model calls until accepted.
struct ProductAgreement: Codable {
    let version: String?
    let termsUrl: String?
    let privacyUrl: String?
    let accepted: Bool?
    let acceptedAt: Double?
}

/// GET /api/permission/saved — every "Always allow" rule, revocable.
struct SavedPermission: Codable, Identifiable {
    let id: String
    let projectID: String?
    let action: String?
    let resource: String?
}

struct SavedPermissionResponse: Codable {
    let data: [SavedPermission]?
}

struct DevEvent: Decodable {
    let id: String?
    let type: String
    let properties: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, type, properties
    }

    func property(_ key: String) -> String? {
        guard case .object(let object)? = properties, let value = object[key] else { return nil }
        if case .string(let text) = value { return text }
        return nil
    }

    func object(_ key: String) -> [String: JSONValue]? {
        guard case .object(let object)? = properties, let value = object[key] else { return nil }
        if case .object(let nested) = value { return nested }
        return nil
    }
}

struct PermissionRequest: Identifiable, Decodable {
    let id: String
    let sessionID: String
    let permission: String?
    let patterns: [String]?
    let action: String?

    var title: String {
        action ?? permission ?? NSLocalizedString("Permission required", comment: "")
    }
    var detail: String { (patterns ?? []).joined(separator: "\n") }

    /// deveco v2 emits a literal "allow" in `action` and puts the actual tool
    /// in `permission`. The old schema used `permission` for the tool and left
    /// `action` nil. Normalize once so cards, rules, and notifications agree.
    var tool: String? {
        if let action, !action.isEmpty, action.lowercased() != "allow", action.lowercased() != "deny" {
            return action
        }
        guard let permission, !permission.isEmpty else { return nil }
        return permission.lowercased() == "allow" || permission.lowercased() == "deny" ? nil : permission
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from deveco server"
        case .status(let code, let body):
            let detail = Self.displayMessage(from: body)
            return String(format: NSLocalizedString("Server error (%lld): %@", comment: ""), Int64(code), detail)
        }
    }

    /// Server error bodies are JSON (often with long stack traces). Show the
    /// actionable message only; keep the raw payload out of the UI.
    static func displayMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let message = payload["message"] as? String else {
            return body
        }
        let firstLine = message
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? message
        return firstLine.isEmpty ? message : firstLine
    }

    /// Category for the failure, so the UI can suggest a concrete next step.
    var kind: FailureKind {
        switch self {
        case .invalidResponse: return .network
        case .status(let code, let body): return .classify(body, statusCode: code)
        }
    }
}

/// Groups failures into actionable buckets — the Codex-style "here is what
/// this is and what you should do" error presentation. Classification is
/// heuristic (status code first, then message keywords) because deveco
/// forwards provider errors as free-form text.
enum FailureKind: String, Equatable {
    case auth, quota, modelUnavailable, network, server, aborted, unknown

    static func classify(_ message: String, statusCode: Int? = nil) -> FailureKind {
        let text = message.lowercased()
        func contains(_ needles: [String]) -> Bool {
            needles.contains { text.contains($0) }
        }

        // An abort is the normal outcome of pressing Stop / Esc. The server
        // reports it as `MessageAbortedError: Aborted`; it must never be
        // surfaced as a failure or retried automatically. Match the abort
        // shapes specifically — a bare "aborted" also matches transport
        // errors such as "connection was aborted", which are real network
        // failures that must stay visible (and retryable).
        if contains(["messageabortederror", "message aborted", "user aborted",
                     "request aborted", "tool execution aborted",
                     "operation aborted", "aborted by user"]) {
            return .aborted
        }

        if let code = statusCode {
            switch code {
            case 401, 403: return .auth
            case 402, 429: return .quota
            case 404: return .modelUnavailable
            case 500...599: return .server
            default: break
            }
        }
        // Bare status numbers are intentionally absent here: free-form provider
        // text routinely contains them ("generated 500 tokens"), and matching
        // them as substrings produced confident but wrong categories. Numeric
        // classification belongs to `statusCode` above, or to the explicit
        // "HTTP 500" / "status 500" forms below.
        if contains(["unauthorized", "forbidden", "invalid api key", "api key",
                     "authentication", "api_key",
                     "http 401", "status 401", "401 unauthorized",
                     "http 403", "status 403", "403 forbidden"]) {
            return .auth
        }
        if contains(["rate limit", "quota", "billing", "insufficient", "credit",
                     "exceeded", "out of tokens",
                     "http 429", "status 429", "429 rate limit"]) {
            return .quota
        }
        if contains(["model not found", "unknown model", "no such model",
                     "does not exist", "not a valid model", "model unavailable",
                     "providermodelnotfound", "provider not found",
                     "unknown provider", "provider not configured",
                     "no provider"]) {
            return .modelUnavailable
        }
        if contains(["connection", "timed out", "timeout", "network", "refused",
                     "could not connect", "unreachable", "econnrefused"]) {
            return .network
        }
        if contains(["internal server", "bad gateway", "service unavailable",
                     "http 500", "status 500", "http 502", "status 502",
                     "http 503", "status 503"]) {
            return .server
        }
        return .unknown
    }

    var label: String {
        switch self {
        case .auth: return NSLocalizedString("Authentication problem", comment: "")
        case .quota: return NSLocalizedString("Quota or rate limit", comment: "")
        case .modelUnavailable: return NSLocalizedString("Model unavailable", comment: "")
        case .network: return NSLocalizedString("Network problem", comment: "")
        case .server: return NSLocalizedString("Server error", comment: "")
        case .aborted: return NSLocalizedString("Stopped", comment: "")
        case .unknown: return NSLocalizedString("Something went wrong", comment: "")
        }
    }

    /// The actionable suggestion shown under the error message.
    var hint: String {
        switch self {
        case .auth:
            return NSLocalizedString("Check the provider's API key in Settings → Models.", comment: "")
        case .quota:
            return NSLocalizedString("Wait a moment and retry, or check the provider's balance and plan.", comment: "")
        case .modelUnavailable:
            return NSLocalizedString("Pick another model from the model menu — this one is not available.", comment: "")
        case .network:
            return NSLocalizedString("Make sure the deveco server is running and your network is reachable.", comment: "")
        case .server:
            return NSLocalizedString("A provider or server hiccup — retrying usually fixes it.", comment: "")
        case .aborted:
            return NSLocalizedString("The generation was stopped.", comment: "")
        case .unknown:
            return NSLocalizedString("If it keeps failing, copy the diagnostics from Settings → Server.", comment: "")
        }
    }

    var symbolName: String {
        switch self {
        case .auth: return "key"
        case .quota: return "gauge"
        case .modelUnavailable: return "cpu"
        case .network: return "wifi.exclamationmark"
        case .server: return "server.rack"
        case .aborted: return "stop.circle"
        case .unknown: return "exclamationmark.triangle"
        }
    }
}

/// Turns a raw provider/server error into a one-line, user-facing summary.
/// Servers wrap failures as "UnknownError: ProviderModelNotFoundError:" and
/// append a JS stack; neither the wrapper nor the stack belongs in the bubble.
func humanizedErrorSummary(_ raw: String, kind: FailureKind) -> String {
    let lines = raw
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard var line = lines.first else { return kind.label }

    // Tool schema errors put the actionable text on line one and the stack
    // on later lines. Keep only line one in the bubble; the full text stays
    // in the inline error's "Show details" disclosure.
    if lines.count > 1, line.hasSuffix(":"), line.count > 12,
       !line.localizedCaseInsensitiveContains("unknownerror"),
       !line.localizedCaseInsensitiveContains("notfounderror") {
        let wrapped = line
        return wrapped
    }

    // Strip chained wrapper prefixes: "UnknownError: FooError: real text".
    // A failed compile must degrade to the raw line instead of trapping while
    // a message bubble is being rendered.
    if let wrapper = try? NSRegularExpression(
        pattern: #"^(?:[A-Za-z_][A-Za-z0-9_]*(?:Error|Exception):\s*)+"#
    ) {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        if let match = wrapper.firstMatch(in: line, range: range),
           let matchRange = Range(match.range, in: line) {
            line = String(line[matchRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
    }

    // Nothing actionable left (only class names): use the category's own text.
    if line.isEmpty {
        switch kind {
        case .modelUnavailable:
            return NSLocalizedString(
                "The selected model is no longer available on the server.",
                comment: "inline error summary when the model id is unknown"
            )
        default:
            return kind.label
        }
    }
    return line
}
