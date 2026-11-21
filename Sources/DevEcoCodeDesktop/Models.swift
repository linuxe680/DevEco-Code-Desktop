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

struct Session: Identifiable, Codable {
    let id: String
    let title: String?
    let directory: String?
    let time: SessionTime?
    let revert: SessionRevert?
    var parentID: String?
    var permission: [PermissionRule]?
    var tokens: MessageTokens?
    var cost: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, directory, time, revert, parentID, permission, tokens, cost
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
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
    let input: Double?
    let output: Double?
    let reasoning: Double?
    let cache: TokenCache?
}

struct TokenCache: Codable {
    let read: Double?
    let write: Double?
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

/// Provider catalogs often include the raw model id in parentheses, e.g.
/// "Hy4 flash (hy4flash)". Drop that suffix for UI labels.
func prettyModelName(_ name: String) -> String {
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
    let status: String?
    let title: String?
    let output: String?
    let error: String?
    let input: JSONValue?
    var time: ToolTime?

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

struct ModelEntry: Identifiable, Hashable {
    var id: String
    var name: String
    var reasoning: Bool
    var context: Int
    var output: Int
    var variants: [String]
}

struct ProviderEntry: Identifiable {
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
}

enum APIError: LocalizedError {
    case invalidResponse
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from deveco server"
        case .status(let code, let body): return "Server returned \(code): \(body)"
        }
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
    case auth, quota, modelUnavailable, network, server, unknown

    static func classify(_ message: String, statusCode: Int? = nil) -> FailureKind {
        let text = message.lowercased()
        func contains(_ needles: [String]) -> Bool {
            needles.contains { text.contains($0) }
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
        if contains(["unauthorized", "forbidden", "invalid api key", "api key",
                     "authentication", "api_key", "401", "403"]) {
            return .auth
        }
        if contains(["rate limit", "quota", "billing", "insufficient", "credit",
                     "exceeded", "429", "out of tokens"]) {
            return .quota
        }
        if contains(["model not found", "unknown model", "no such model",
                     "does not exist", "not a valid model", "model unavailable"]) {
            return .modelUnavailable
        }
        if contains(["connection", "timed out", "timeout", "network", "refused",
                     "could not connect", "unreachable", "econnrefused"]) {
            return .network
        }
        if contains(["internal server", "500", "502", "503", "bad gateway"]) {
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
        case .unknown: return "exclamationmark.triangle"
        }
    }
}
