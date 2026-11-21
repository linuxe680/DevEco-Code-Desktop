import Foundation
import Combine
import UserNotifications
import AppKit

struct PendingAttachment: Identifiable {
    let id = UUID()
    let mime: String
    let filename: String?
    /// `data:` URL for pasted images, `file:` URL for project-local files.
    let url: String
    /// Small preview bytes for pasted images (chip thumbnails).
    let thumbnail: Data?
}

/// Everything needed to send one prompt, captured at submission time.
/// Queueing and retrying must never read mutable composer state later.
struct PromptSnapshot {
    let text: String
    let model: String?
    let variant: String?
    let attachments: [PendingAttachment]
}

struct QueuedPrompt: Identifiable {
    let id: UUID
    let prompt: PromptSnapshot

    var text: String { prompt.text }
    var model: String? { prompt.model }
    var attachments: [PendingAttachment] { prompt.attachments }

    init(id: UUID = UUID(), prompt: PromptSnapshot) {
        self.id = id
        self.prompt = prompt
    }

    init(
        id: UUID = UUID(),
        text: String,
        model: String?,
        variant: String? = nil,
        attachments: [PendingAttachment] = []
    ) {
        self.id = id
        self.prompt = PromptSnapshot(
            text: text,
            model: model,
            variant: variant,
            attachments: attachments
        )
    }
}

@MainActor
final class SessionStore: ObservableObject {
    typealias PendingAttachment = DevEcoCodeDesktop.PendingAttachment
    typealias PromptSnapshot = DevEcoCodeDesktop.PromptSnapshot
    typealias QueuedPrompt = DevEcoCodeDesktop.QueuedPrompt

    @Published var sessions: [Session] = []
    @Published var selectedSessionID: String?
    @Published var messages: [MessageRecord] = []
    @Published private(set) var isLoadingMessages = false
    @Published var pendingPermissions: [PermissionRequest] = []
    /// Sessions with an in-flight prompt or abort. Keeping this per-session
    /// prevents a busy background chat from hijacking the composer when the
    /// user switches to an idle conversation.
    @Published private(set) var activeSessionIDs: Set<String> = []
    /// Client-side pinned sessions (the server has no pin field); ordering
    /// follows pin order, newest pin first.
    @Published private(set) var pinnedSessionIDs: [String] = AppSettings.pinnedSessionIDs
    /// Durable "always allow" rules the client records itself; the deveco
    /// server only remembers them for the lifetime of one server process.
    @Published private(set) var savedPermissionRules: [String] = AppSettings.savedPermissionRules
    @Published private(set) var abortingSessionIDs: Set<String> = []
    var isSending: Bool {
        guard let id = selectedSessionID else { return false }
        return activeSessionIDs.contains(id) || abortingSessionIDs.contains(id)
    }
    @Published var errorMessage: String?
    /// Human-readable retry info from session.status (e.g. "attempt 2: rate limited").
    @Published private var retryInfoBySession: [String: String] = [:]
    var retryInfo: String? {
        guard let id = selectedSessionID else { return nil }
        return retryInfoBySession[id]
    }
    /// Todo list for the selected session, from todo.updated / GET session/{id}/todo.
    @Published var todos: [TodoItem] = []
    /// File changes of the selected session, from session.diff / GET session/{id}/diff.
    @Published var diffs: [FileDiff] = []
    @Published var isLoadingDiff = false
    @Published var isCompacting = false
    /// Pending "agent asks the user" requests, from question.asked events.
    @Published var pendingQuestions: [UserQuestionRequest] = []
    /// Current git branch of the project (GET /vcs + vcs.branch.updated).
    @Published var vcsBranch: String?
    /// Aggregated usage for the project (GET /stats/usage).
    @Published var usage: UsageSummary?
    /// Slash commands, skills, and MCP prompts (GET /command).
    @Published private(set) var commands: [DevCommand] = []
    /// Per-session activity ("busy"/"retry"/"idle") from session.status events,
    /// for sidebar indicators across all sessions.
    @Published private(set) var sessionStatuses: [String: String] = [:]
    /// Prompts queued while the selected session is generating; flushed on idle.
    @Published private(set) var queuedPrompts: [QueuedPrompt] = []
    /// The server reported a newer deveco version (installation.update-available).
    @Published var updateAvailable = false
    /// deveco blocks model calls until its product agreement is accepted.
    @Published private(set) var productAgreement: ProductAgreement?
    @Published private(set) var needsConsent = false
    @Published private(set) var isAcceptingConsent = false
    /// Session-scoped errors shown inside the conversation (with Retry).
    /// Keeping the dictionary means a background failure is still visible
    /// after the user switches to that session later.
    @Published private var inlineErrorsBySession: [String: InlineError] = [:]
    var inlineError: InlineError? {
        guard let id = selectedSessionID else { return nil }
        return inlineErrorsBySession[id]
    }
    /// Background sessions that finished while another conversation was open.
    @Published private(set) var unreadSessionIDs: Set<String> = []
    /// Last time streaming activity (delta/updated) reached the store —
    /// drives the stuck-detection hint in the generating indicator.
    @Published private(set) var lastStreamActivity = Date()
    /// Attachments queued for the next prompt (pasted images as data URLs,
    /// project-local files as file URLs).
    @Published private(set) var attachments: [PendingAttachment] = []
    private var attachmentsBySession: [String: [PendingAttachment]] = [:]

    /// Images above this size get downscaled before sending.
    static let maxImageBytes = 1_500_000
    private static let maxImageDimension: CGFloat = 1568

    /// Adds a pasted image; sent inline as a data URL — no files written.
    /// Oversized images are downscaled (longest side ≤ 1568, JPEG 0.85);
    /// if compression fails the original is sent and the user is warned.
    func addImageAttachment(data: Data, filename: String? = nil) {
        guard selectedSessionID != nil else { return }
        var payload = data
        var mime = "image/png"
        if data.count > Self.maxImageBytes {
            if let compressed = Self.downscaledImage(from: data) {
                payload = compressed
                mime = "image/jpeg"
            } else if NSImage(data: data) == nil {
                errorMessage = NSLocalizedString(
                    "Couldn't read the pasted image — it will be sent as raw bytes.",
                    comment: ""
                )
            } else {
                errorMessage = NSLocalizedString(
                    "Couldn't compress the large image; sending the original.",
                    comment: ""
                )
            }
        }
        appendAttachment(PendingAttachment(
            mime: mime,
            filename: filename,
            url: "data:\(mime);base64," + payload.base64EncodedString(),
            thumbnail: Self.thumbnailData(from: payload)
        ))
    }

    /// Downscale helper. Uses **pixel** dimensions (cgImage) rather than
    /// NSImage.size (points): on Retina displays points are half the pixels,
    /// which used to let a 3136px output slip past the 1568 cap.
    /// nil = keep the original (too small or decode failed).
    static func downscaledImage(from data: Data) -> Data? {
        guard let resized = scaledPixelImage(from: data, maxDimension: maxImageDimension) else { return nil }
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
              jpeg.count < data.count else { return nil }
        return jpeg
    }

    /// Tiny preview for the attachment chip.
    private static func thumbnailData(from data: Data) -> Data? {
        guard let resized = scaledPixelImage(from: data, maxDimension: 64) else { return nil }
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    /// High-quality resample bounded by pixel dimensions; nil when the source
    /// already fits (or decode failed).
    private static func scaledPixelImage(from data: Data, maxDimension: CGFloat) -> NSImage? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxDimension else { return nil }
        let scale = maxDimension / longest
        let newWidth = max(1, Int((pixelWidth * scale).rounded()))
        let newHeight = max(1, Int((pixelHeight * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: newWidth, height: newHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let resized = context.makeImage() else { return nil }
        // 1:1 points-to-pixels so downstream size checks see true pixel dims.
        return NSImage(cgImage: resized, size: NSSize(width: newWidth, height: newHeight))
    }

    /// Adds a file reference. The server only reads paths inside the project
    /// root (verified live), so the caller validates before calling.
    func addFileAttachment(url: URL) {
        guard selectedSessionID != nil else { return }
        let mime: String = {
            switch url.pathExtension.lowercased() {
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            case "pdf": return "application/pdf"
            case "txt", "md": return "text/plain"
            default: return "application/octet-stream"
            }
        }()
        appendAttachment(PendingAttachment(
            mime: mime,
            filename: url.lastPathComponent,
            url: url.absoluteString,
            thumbnail: nil
        ))
    }

    func removeAttachment(_ attachment: PendingAttachment) {
        guard let id = selectedSessionID else { return }
        attachments.removeAll { $0.id == attachment.id }
        attachmentsBySession[id] = attachments
    }

    private func appendAttachment(_ attachment: PendingAttachment) {
        guard let id = selectedSessionID else { return }
        attachments.append(attachment)
        attachmentsBySession[id] = attachments
    }

    struct InlineError: Identifiable, Equatable {
        let id = UUID()
        let sessionID: String
        let message: String
        var kind: FailureKind = .unknown
    }

    /// One compact sidebar indicator, in user-priority order. A blocked
    /// permission/question or a failure is more important than activity.
    struct SessionIndicator: Equatable {
        enum Kind: Equatable {
            case permission
            case question
            case failed
            case retry
            case busy
            case unread
        }

        let kind: Kind
        let count: Int
    }

    func indicator(for sessionID: String) -> SessionIndicator? {
        let permissions = pendingPermissions.filter { $0.sessionID == sessionID }.count
        if permissions > 0 {
            return SessionIndicator(kind: .permission, count: permissions)
        }
        let questions = pendingQuestions.filter { $0.sessionID == sessionID }.count
        if questions > 0 {
            return SessionIndicator(kind: .question, count: questions)
        }
        if inlineErrorsBySession[sessionID] != nil {
            return SessionIndicator(kind: .failed, count: 1)
        }
        if sessionStatuses[sessionID] == "retry" {
            return SessionIndicator(kind: .retry, count: 1)
        }
        if activeSessionIDs.contains(sessionID) {
            return SessionIndicator(kind: .busy, count: 1)
        }
        if unreadSessionIDs.contains(sessionID) {
            return SessionIndicator(kind: .unread, count: 1)
        }
        return nil
    }

    /// True while the event stream is down and reconnect attempts are pending;
    /// drives the connection status strip.
    @Published private(set) var isReconnecting = false
    /// How many reconnect attempts have been made since the stream dropped.
    var reconnectAttemptCount: Int { reconnectAttempts }
    @Published var draft = ""
    @Published var selectedModel: String? {
        didSet {
            if oldValue != selectedModel {
                selectedVariant = nil
            }
            stashModelForSelectedSession()
        }
    }
    /// Reasoning-effort style variant for the selected model (nil = default).
    @Published var selectedVariant: String? {
        didSet {
            stashVariantForSelectedSession()
        }
    }
    /// Bumped whenever the transcript mutates; drives follow-scroll in the chat view.
    @Published private(set) var streamTick = 0

    private var api: APIClient?
    private let eventStream = EventStream()

    private var retryTask: Task<Void, Never>?
    private var pollTasksBySession: [String: Task<Void, Never>] = [:]
    /// 后台会话在 idle 时抓取的消息快照。切回该会话时先展示缓存，
    /// 避免 SSE 增量因 `sessionID != selectedSessionID` 被丢弃后只显示空态。
    private var messagesCacheBySession: [String: [MessageRecord]] = [:]
    private var reconnectAttempts = 0
    /// Drafts stashed per session so switching preserves in-progress text.
    private var draftsBySession: [String: String] = [:]
    /// Queues stashed per session (only the selected session's is published).
    private var queuesBySession: [String: [QueuedPrompt]] = [:]
    /// Per-session model/variant picks, restored on switch and persisted
    /// across restarts (AppSettings.sessionModels/sessionVariants).
    private var modelsBySession: [String: String] = AppSettings.sessionModels
    private var variantsBySession: [String: String] = AppSettings.sessionVariants
    /// The server's configured default model ("providerID/modelID"), mirroring
    /// GET /config's `model`. Used when a session has no explicit pick so new
    /// sessions show (and send) the real model instead of "Server default".
    var serverDefaultModel = ""
    private var autoTitleInFlight = Set<String>()
    /// Last sent prompt per session, for exact-context retry after an error.
    private var lastSentPromptBySession: [String: PromptSnapshot] = [:]
    /// Automatic retry counter for network-class failures, per session; reset
    /// when the user sends again so a broken network can't loop forever.
    private var autoRetryCountBySession: [String: Int] = [:]
    /// Streaming deltas buffered between flushes (~120ms batches).
    private var pendingDeltas: [String: String] = [:]
    private var lastDeltaFlush = Date.distantPast

    private static let cacheSessionsKey = "cachedSessions"
    private static let cacheSelectedKey = "cachedSelectedSession"

    init() {
        // Show last known sessions immediately; the server refresh replaces
        // them once connected.
        if let data = UserDefaults.standard.data(forKey: Self.cacheSessionsKey),
           let cached = try? JSONDecoder.deveco.decode([Session].self, from: data), !cached.isEmpty {
            sessions = cached
        }
        if let id = UserDefaults.standard.string(forKey: Self.cacheSelectedKey),
           sessions.contains(where: { $0.id == id }) {
            selectedSessionID = id
        }
        eventStream.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        eventStream.onDisconnect = { [weak self] in
            Task { @MainActor in self?.scheduleReconnect() }
        }
        // 设置页撤销权限后，服务端规则是唯一真相，同步刷新本地缓存。
        NotificationCenter.default.addObserver(
            forName: .savedPermissionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.savedPermissionRules = AppSettings.savedPermissionRules
            }
        }
    }

    func connect(baseURL: URL) {
        api = APIClient(baseURL: baseURL)
        reconnectAttempts = 0
        isReconnecting = false
        eventStream.connect(baseURL: baseURL)
        if selectedModel == nil {
            let preferred = AppSettings.defaultSessionModel
            if !preferred.isEmpty { selectedModel = preferred }
        }
        Task { await refresh() }
        Task { await refreshPendingRequests() }
        Task { await loadBranch() }
        Task { await loadUsage() }
        Task { await loadCommands() }
        Task { await loadAgreement() }
        Task { await syncSavedPermissionsFromServer() }
    }

    /// 以服务端 /api/permission/saved 为准刷新本地"Always allow"缓存，
    /// 避免设置页撤销后客户端仍按旧规则自动放行。
    private func syncSavedPermissionsFromServer() async {
        guard let api else { return }
        do {
            let response: SavedPermissionResponse = try await api.get("api/permission/saved")
            let rules = (response.data ?? []).compactMap { saved -> String? in
                let action = saved.action ?? ""
                let resource = saved.resource ?? ""
                if action.isEmpty { return nil }
                return resource.isEmpty ? "\(action)|" : "\(action)|\(resource)"
            }
            savedPermissionRules = rules
            AppSettings.savedPermissionRules = rules
        } catch {
            // 服务端不可用时保留上次缓存，不阻塞连接。
        }
    }

    func disconnect() {
        api = nil
        eventStream.disconnect()
        isReconnecting = false
        retryTask?.cancel()
        retryTask = nil
        pollTasksBySession.values.forEach { $0.cancel() }
        pollTasksBySession = [:]
        activeSessionIDs = []
        abortingSessionIDs = []
        sessions = []
        messages = []
        isLoadingMessages = false
        pendingPermissions = []
        pendingQuestions = []
        inlineErrorsBySession = [:]
        unreadSessionIDs = []
        todos = []
        diffs = []
        retryInfoBySession = [:]
        vcsBranch = nil
        usage = nil
        commands = []
        attachments = []
        attachmentsBySession = [:]
    }

    var selectedSession: Session? {
        sessions.first { $0.id == selectedSessionID }
    }

    func refresh() async {
        guard let api else { return }
        do {
            sessions = try await api.get("session")
            let ids = Set(sessions.map(\.id))
            sessionStatuses = sessionStatuses.filter { ids.contains($0.key) }
            unreadSessionIDs.formIntersection(ids)
            inlineErrorsBySession = inlineErrorsBySession.filter { ids.contains($0.key) }
            // Drop per-session picks for deleted sessions.
            if modelsBySession.count > ids.count || variantsBySession.count > ids.count {
                modelsBySession = modelsBySession.filter { ids.contains($0.key) }
                variantsBySession = variantsBySession.filter { ids.contains($0.key) }
                AppSettings.sessionModels = modelsBySession
                AppSettings.sessionVariants = variantsBySession
            }
            persistCache()
            // Open on the most recent conversation instead of a dead input.
            if selectedSessionID == nil || !ids.contains(selectedSessionID ?? "") {
                autoSelectRecentSession()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-fetches permission/question requests that fired while the app was
    /// closed (SSE is only live while connected, so restarts miss them).
    func refreshPendingRequests() async {
        guard let api else { return }
        do {
            let pending: [UserQuestionRequest] = try await api.get("question")
            pendingQuestions = pending
        } catch {
            // Non-fatal: the stream will deliver new asks, and the transcript
            // still shows the tool call awaiting an answer.
        }
    }

    /// Persists the session list and selection so restarts open instantly.
    private func persistCache() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.cacheSessionsKey)
        }
        UserDefaults.standard.set(selectedSessionID, forKey: Self.cacheSelectedKey)
    }

    func createSession() {
        guard let api else {
            errorMessage = NSLocalizedString("Not connected yet — wait for the server to start.", comment: "")
            return
        }
        let body = ["title": "New session"]
        Task {
            do {
                let session: Session = try await api.post("session", body: try body.jsonData())
                sessions.insert(session, at: 0)
                select(session.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func select(_ id: String) {
        guard selectedSessionID != id else { return }
        if let old = selectedSessionID {
            // Background fallback polling only serves the visible transcript;
            // switching away would otherwise leave a 2s idle wakeup running.
            // select() restarts it when the session comes back.
            stopPolling(for: old)
            draftsBySession[old] = draft
            queuesBySession[old] = queuedPrompts
            attachmentsBySession[old] = attachments
            modelsBySession[old] = selectedModel ?? ""
            variantsBySession[old] = selectedVariant ?? ""
            // 切走前保存当前会话的转写，供再次切回时秒显。
            if !messages.isEmpty { messagesCacheBySession[old] = messages }
        }
        unreadSessionIDs.remove(id)
        selectedSessionID = id
        persistCache()
        // 后台会话空闲时已抓过快照，先展示它，避免空白闪烁。
        messages = messagesCacheBySession[id] ?? []
        isLoadingMessages = true
        todos = []
        diffs = []
        pendingDeltas.removeAll()
        draft = draftsBySession[id] ?? ""
        queuedPrompts = queuesBySession[id] ?? []
        attachments = attachmentsBySession[id] ?? []
        // Restore this session's model/variant pick. Capture both BEFORE any
        // assignment: setting selectedModel cascades (didSet resets
        // selectedVariant, whose didSet re-stashes) and would otherwise
        // clobber the stored variant for the new session before it's read.
        //
        // "" entry = user explicitly chose "Server default" for this session;
        // no entry = fall back to the app-wide default model.
        let restoredVariant = variantsBySession[id].flatMap { $0.isEmpty ? nil : $0 }
        let globalDefault: String? = {
            if !AppSettings.defaultSessionModel.isEmpty {
                return AppSettings.defaultSessionModel
            }
            return serverDefaultModel.isEmpty ? nil : serverDefaultModel
        }()
        let restoredModel = modelsBySession[id].map { $0.isEmpty ? nil : $0 } ?? globalDefault
        selectedModel = restoredModel
        selectedVariant = restoredVariant
        Task { await loadMessages() }
        Task { await loadTodos() }
        if activeSessionIDs.contains(id), !abortingSessionIDs.contains(id) {
            startFallbackPolling(for: id)
        }
        flushQueue(for: id)
    }

    private func stashModelForSelectedSession() {
        guard let id = selectedSessionID else { return }
        modelsBySession[id] = selectedModel ?? ""
        AppSettings.sessionModels = modelsBySession
    }

    private func stashVariantForSelectedSession() {
        guard let id = selectedSessionID else { return }
        variantsBySession[id] = selectedVariant ?? ""
        AppSettings.sessionVariants = variantsBySession
    }

    func loadTodos() async {
        guard let api, let id = selectedSessionID else { return }
        do {
            let fetched: [TodoItem] = try await api.get("session/\(id)/todo")
            guard id == selectedSessionID else { return }
            todos = fetched
        } catch {
            // Todos are optional decoration; ignore fetch failures quietly.
        }
    }

    func loadDiff() async {
        guard let api, let id = selectedSessionID else { return }
        isLoadingDiff = true
        defer { isLoadingDiff = false }
        do {
            let fetched: [FileDiff] = try await api.get("session/\(id)/diff")
            guard id == selectedSessionID else { return }
            diffs = fetched
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Compresses the conversation context (POST /session/{id}/compact).
    /// Verified live: only the bare route exists in deveco 0.3.0 — the /api/
    /// variant answers 503.
    func compact() async {
        guard let api, let id = selectedSessionID, !isCompacting else { return }
        isCompacting = true
        defer { isCompacting = false }
        do {
            try await api.postNoContent("session/\(id)/compact")
            await loadMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rolls the session back to just before the given message.
    func revert(to message: MessageRecord) async {
        guard let api, let id = selectedSessionID else { return }
        do {
            let body = ["messageID": message.id]
            let updated: Session = try await api.post("session/\(id)/revert", body: try body.jsonData())
            upsert(updated)
            await loadMessages()
            // The rollback changes the file set; stale diffs/todos mislead.
            Task { await loadDiff() }
            Task { await loadTodos() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unrevert() async {
        guard let api, let id = selectedSessionID else { return }
        do {
            try await api.postNoContent("session/\(id)/unrevert")
            await refresh()
            await loadMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes the session transcript as Markdown to the given file URL.
    func export(_ session: Session, to url: URL) async throws {
        guard let api else {
            throw NSError(
                domain: "Export",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot export while the server is not connected."]
            )
        }
        let messages: [MessageRecord] = try await api.get("session/\(session.id)/message")
        let markdown = TranscriptExporter.markdown(session: session, messages: messages)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Agent questions

    /// Replies to a question request; one array of selected labels per question.
    func answer(_ request: UserQuestionRequest, answers: [[String]]) async {
        guard let api else { return }
        do {
            let body = ["answers": answers]
            try await api.postNoContent("question/\(request.id)/reply", body: body.jsonData())
            pendingQuestions.removeAll { $0.id == request.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Skips a question request; the agent decides how to proceed.
    func rejectQuestion(_ request: UserQuestionRequest) async {
        guard let api else { return }
        do {
            try await api.postNoContent("question/\(request.id)/reject")
            pendingQuestions.removeAll { $0.id == request.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Project-level info

    func loadBranch() async {
        guard let api else { return }
        do {
            let info: VcsInfo = try await api.get("vcs")
            vcsBranch = info.branch
        } catch {
            // Non-git projects are fine; leave the branch hidden.
        }
    }

    func loadUsage() async {
        guard let api else { return }
        do {
            usage = try await api.get("stats/usage")
        } catch {
            // Usage is optional decoration; ignore fetch failures quietly.
        }
    }

    func loadCommands() async {
        guard let api else { return }
        do {
            let fetched: [DevCommand] = try await api.get("command")
            commands = fetched.sorted { $0.name < $1.name }
        } catch {
            // Commands are optional decoration; ignore fetch failures quietly.
        }
    }

    func loadAgreement() async {
        guard let api else { return }
        do {
            let agreement: ProductAgreement = try await api.get("global/product-agreement")
            productAgreement = agreement
            needsConsent = agreement.accepted == false
        } catch {
            // Older servers may not expose the endpoint; don't nag.
        }
    }

    /// Accepts the product agreement via the deveco CLI, then re-checks.
    func acceptConsent() async {
        guard !isAcceptingConsent else { return }
        isAcceptingConsent = true
        defer { isAcceptingConsent = false }
        let ok = await Task.detached {
            ServerManager.acceptProductAgreement()
        }.value
        if ok {
            await loadAgreement()
        } else {
            errorMessage = NSLocalizedString(
                "Consent failed — run `deveco auth consent --accept` in a terminal.",
                comment: ""
            )
        }
    }

    /// 加载会话消息。传入 `sessionID` 用于后台会话快照（只写缓存，不覆盖 UI）；
    /// 不传则加载当前选中会话并更新 `messages`。
    func loadMessages(for sessionID: String? = nil) async {
        guard let api, let id = sessionID ?? selectedSessionID else {
            if sessionID == nil { isLoadingMessages = false }
            return
        }
        let isVisible = id == selectedSessionID
        if isVisible { isLoadingMessages = true }
        defer {
            if isVisible && id == selectedSessionID { isLoadingMessages = false }
        }
        do {
            let fetched: [MessageRecord] = try await api.get("session/\(id)/message")
            if !isVisible {
                // 后台快照：只缓存，绝不触碰当前 UI 状态。
                messagesCacheBySession[id] = fetched
                return
            }
            // Another select may have happened while the request was in flight.
            guard id == selectedSessionID else {
                messagesCacheBySession[id] = fetched
                return
            }
            messages = fetched
            messagesCacheBySession[id] = fetched
            // The snapshot supersedes every buffered delta: the server writes
            // state before emitting events, so anything still buffered is
            // already included in `fetched`. Keeping it would append the same
            // text twice (the fallback poll runs every 2s mid-stream).
            pendingDeltas.removeAll()
            autoTitleFromFirstMessageIfNeeded()
        } catch {
            guard id == selectedSessionID else { return }
            errorMessage = error.localizedDescription
        }
    }

    func send() {
        guard api != nil, let sessionID = selectedSessionID else { return }
        var state = composerState(for: sessionID)
        guard let submission = state.submit(
            model: selectedModel,
            variant: selectedVariant,
            isBusy: isSending
        ) else { return }
        applyComposerState(state, for: sessionID)
        let prompt = submission.snapshot
        recordHistory(prompt.text)

        // While the session generates (or an abort is still landing), prompts
        // join a queue that flushes on idle.
        if submission.queued {
            enqueue(QueuedPrompt(prompt: prompt), for: sessionID)
            return
        }
        if !performSend(prompt, sessionID: sessionID) {
            enqueue(QueuedPrompt(prompt: prompt), for: sessionID)
        }
    }

    func removeQueued(_ prompt: QueuedPrompt) {
        guard let id = selectedSessionID else { return }
        var state = composerState(for: id)
        state.removeQueued(id: prompt.id)
        setQueue(state.queue, for: id)
    }

    /// Pulls a queued prompt back into the input for editing. Any draft the
    /// user has already typed is re-queued instead of being overwritten.
    func editQueued(_ prompt: QueuedPrompt) {
        guard let id = selectedSessionID else { return }
        var state = composerState(for: id)
        state.editQueued(prompt, model: selectedModel, variant: selectedVariant)
        applyComposerState(state, for: id)
    }

    /// Aborts the current generation (keeping the rest of the queue) and
    /// sends this queued prompt immediately. Waits for the abort response so
    /// the server is idle before prompt_async lands.
    func sendQueuedNow(_ prompt: QueuedPrompt) async {
        guard let id = selectedSessionID else { return }
        var state = composerState(for: id)
        state.removeQueued(id: prompt.id)
        setQueue(state.queue, for: id)
        await performAbort(sessionID: id, clearQueue: false, flushAfter: false)
        if !performSend(prompt.prompt, sessionID: id) {
            enqueue(prompt, for: id, atFront: true)
        }
    }

    /// Reorders the queue: moves `id` directly before `targetID`.
    func moveQueued(_ id: UUID, before targetID: UUID) {
        guard let sessionID = selectedSessionID else { return }
        var state = composerState(for: sessionID)
        state.moveQueued(id: id, before: targetID)
        setQueue(state.queue, for: sessionID)
    }

    private func composerState(for sessionID: String) -> ComposerState {
        var state = ComposerState()
        state.draft = sessionID == selectedSessionID ? draft : (draftsBySession[sessionID] ?? "")
        state.attachments = sessionID == selectedSessionID
            ? attachments
            : (attachmentsBySession[sessionID] ?? [])
        state.queue = queue(for: sessionID)
        return state
    }

    private func applyComposerState(_ state: ComposerState, for sessionID: String) {
        guard sessionID == selectedSessionID else {
            draftsBySession[sessionID] = state.draft
            attachmentsBySession[sessionID] = state.attachments
            setQueue(state.queue, for: sessionID)
            return
        }
        draft = state.draft
        attachments = state.attachments
        attachmentsBySession[sessionID] = state.attachments
        setQueue(state.queue, for: sessionID)
    }

    /// Sends one immutable prompt to a specific session. Returns false if it
    /// was rejected (mid-abort, already generating, disconnected) — callers
    /// MUST put the snapshot back somewhere visible.
    @discardableResult
    private func performSend(_ prompt: PromptSnapshot, sessionID id: String) -> Bool {
        guard let api,
              !activeSessionIDs.contains(id),
              !abortingSessionIDs.contains(id) else {
            return false
        }
        activeSessionIDs.insert(id)
        inlineErrorsBySession.removeValue(forKey: id)
        lastSentPromptBySession[id] = prompt
        autoRetryCountBySession[id] = 0
        autoTitleIfNeeded(sessionID: id, prompt: prompt.text)

        // "/name args…" matching a registered command goes to the dedicated
        // command endpoint (same routing the official TUI/client does).
        if prompt.text.hasPrefix("/"), let slash = parseSlashCommand(prompt.text) {
            Task {
                do {
                    var body: [String: Any] = ["command": slash.name]
                    if let arguments = slash.arguments, !arguments.isEmpty {
                        body["arguments"] = arguments
                    }
                    if let model = prompt.model {
                        let pieces = model.split(separator: "/", maxSplits: 1)
                        if pieces.count == 2 {
                            body["model"] = ["providerID": String(pieces[0]), "modelID": String(pieces[1])]
                        }
                    }
                    let data = try? JSONSerialization.data(withJSONObject: body)
                    let _: EmptyResponse = try await api.post("session/\(id)/command", body: data)
                    await refreshMessagesIfSelected(id)
                    startFallbackPolling(for: id)
                } catch {
                    recordSessionFailure(id, message: error.localizedDescription)
                    finishRun(id)
                    // The command never reached the server; surface it with
                    // Retry instead of silently dropping the text.
                }
            }
            return true
        }

        var parts: [[String: Any]] = []
        for attachment in prompt.attachments {
            var filePart: [String: Any] = [
                "type": "file",
                "mime": attachment.mime,
                "url": attachment.url,
            ]
            if let filename = attachment.filename {
                filePart["filename"] = filename
            }
            parts.append(filePart)
        }
        parts.append(["type": "text", "text": prompt.text])

        var body: [String: Any] = ["parts": parts]
        if let model = prompt.model {
            let pieces = model.split(separator: "/", maxSplits: 1)
            if pieces.count == 2 {
                body["model"] = ["providerID": String(pieces[0]), "modelID": String(pieces[1])]
            }
        }
        if let variant = prompt.variant {
            body["variant"] = variant
        }
        let data = try? JSONSerialization.data(withJSONObject: body)
        Task {
            do {
                let _: EmptyResponse = try await api.post("session/\(id)/prompt_async", body: data)
                await refreshMessagesIfSelected(id)
                startFallbackPolling(for: id)
                // The session stays active until the server reports idle.
            } catch {
                recordSessionFailure(id, message: error.localizedDescription)
                finishRun(id)
                // The prompt never reached the server; keep it recoverable
                // via the inline Retry instead of silently losing the text.
            }
        }
        return true
    }

    private func queue(for sessionID: String) -> [QueuedPrompt] {
        if sessionID == selectedSessionID {
            return queuedPrompts
        }
        return queuesBySession[sessionID] ?? []
    }

    private func setQueue(_ queue: [QueuedPrompt], for sessionID: String) {
        queuesBySession[sessionID] = queue
        if sessionID == selectedSessionID {
            queuedPrompts = queue
        }
    }

    private func enqueue(_ prompt: QueuedPrompt, for sessionID: String, atFront: Bool = false) {
        var queue = queue(for: sessionID)
        if atFront {
            queue.insert(prompt, at: 0)
        } else {
            queue.append(prompt)
        }
        setQueue(queue, for: sessionID)
    }

    private func flushQueue(for sessionID: String) {
        guard !activeSessionIDs.contains(sessionID),
              !abortingSessionIDs.contains(sessionID) else { return }
        var queue = queue(for: sessionID)
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        setQueue(queue, for: sessionID)
        if !performSend(next.prompt, sessionID: sessionID) {
            // Rejected (racing an abort, or still busy): put it back at the
            // front so ordering is preserved and the next idle retries.
            enqueue(next, for: sessionID, atFront: true)
        }
    }

    /// Remembers recently sent prompts for Option+↑/↓ recall.
    private func recordHistory(_ text: String) {
        var history = AppSettings.promptHistory
        history.removeAll { $0 == text }
        history.append(text)
        AppSettings.promptHistory = history
    }

    /// Give brand-new sessions a recognizable title from the first prompt.
    private func autoTitleIfNeeded(sessionID: String, prompt: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        guard isPlaceholderTitle(session.title), let title = titleSeed(from: prompt) else { return }
        applyAutoTitle(title, to: session)
    }

    /// Covers sessions created before auto-title existed, or a send-time
    /// rename that failed transiently: once messages load, fill the
    /// placeholder title from the first user message.
    private func autoTitleFromFirstMessageIfNeeded() {
        guard let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }),
              isPlaceholderTitle(session.title) else { return }
        let firstPrompt = messages
            .first(where: { $0.info.role == "user" })?
            .parts
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n") ?? ""
        guard let title = titleSeed(from: firstPrompt) else { return }
        applyAutoTitle(title, to: session)
    }

    private func isPlaceholderTitle(_ title: String?) -> Bool {
        let value = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty
            || value == "new session"
            || value == "untitled session"
            || value == NSLocalizedString("New session", comment: "").lowercased()
            || value == NSLocalizedString("Untitled session", comment: "").lowercased()
    }

    private func titleSeed(from text: String) -> String? {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !firstLine.isEmpty, !firstLine.hasPrefix("/") else { return nil }
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
    }

    private func applyAutoTitle(_ title: String, to session: Session) {
        guard !autoTitleInFlight.contains(session.id) else { return }
        autoTitleInFlight.insert(session.id)
        Task {
            await rename(session, to: title)
            autoTitleInFlight.remove(session.id)
        }
    }

    /// File search for @-mentions (paths relative to the project root).
    /// An empty query lists files too, so "@" alone shows the picker.
    func findFiles(query: String) async -> [FsEntry] {
        guard let api else { return [] }
        do {
            let response: FsFindResponse = try await api.get("api/fs/find", query: ["query": query])
            return (response.data ?? []).filter {
                ($0.type == "file" || $0.mime != nil) && Self.isSearchablePath($0.path)
            }
        } catch {
            return []
        }
    }

    /// Paths the @ picker should not offer: anything inside a dot-directory
    /// (.git, .build), node_modules, plus log/temp dumps the server surfaces.
    nonisolated static func isSearchablePath(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        if components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) { return false }
        return !path.hasSuffix(".log") && !path.hasSuffix(".tmp")
    }

    /// Edits a past user message: reverts the session to just before it and
    /// prefills the input with its text for re-sending.
    func editMessage(_ message: MessageRecord) async {
        guard let api, let id = selectedSessionID, message.info.role == "user" else { return }
        let text = message.parts
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined(separator: "\n")
        do {
            let body = ["messageID": message.info.id]
            let updated: Session = try await api.post("session/\(id)/revert", body: try body.jsonData())
            upsert(updated)
            await loadMessages()
            Task { await loadDiff() }
            Task { await loadTodos() }
            draft = text
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private struct SlashCommand {
        let name: String
        let arguments: String?
    }

    private func parseSlashCommand(_ text: String) -> SlashCommand? {
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
        guard let first = parts.first else { return nil }
        let name = String(first)
        guard commands.contains(where: { $0.name == name }) else { return nil }
        return SlashCommand(name: name, arguments: parts.count > 1 ? String(parts[1]) : nil)
    }

    /// Duplicates a session server-side (POST /session/{id}/fork) and selects it.
    func fork(_ session: Session) async {
        guard let api else { return }
        do {
            let newSession: Session = try await api.post("session/\(session.id)/fork", body: nil)
            upsert(newSession)
            select(newSession.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ session: Session, to title: String) async {
        guard let api else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.title else { return }
        do {
            let body = ["title": trimmed]
            let updated: Session = try await api.patch("session/\(session.id)", body: try body.jsonData())
            upsert(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setArchived(_ session: Session, _ archived: Bool) async {
        guard let api else { return }
        let stamp: Double = archived ? Date().timeIntervalSince1970 * 1000 : 0
        do {
            let body = ["time": ["archived": stamp]]
            let updated: Session = try await api.patch("session/\(session.id)", body: try body.jsonData())
            upsert(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSession(_ session: Session) async {
        guard let api else { return }
        do {
            try await api.delete("session/\(session.id)")
            applyDeletion(of: session.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Pins or unpins a session; pinning puts it at the top of the list.
    func togglePinned(_ id: String, pinned: Bool? = nil) {
        var ids = pinnedSessionIDs
        let isPinned = ids.contains(id)
        let target = pinned ?? !isPinned
        if target == isPinned { return }
        if target {
            ids.removeAll { $0 == id }
            ids.insert(id, at: 0)
        } else {
            ids.removeAll { $0 == id }
        }
        pinnedSessionIDs = ids
        AppSettings.pinnedSessionIDs = ids
    }

    /// Opens the most recent non-archived session when nothing is selected.
    private func autoSelectRecentSession() {
        guard selectedSessionID == nil, !sessions.isEmpty else { return }
        let recent = sessions
            .filter { !$0.isArchived }
            .max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
        if let recent {
            select(recent.id)
        }
    }

    private func applyDeletion(of id: String) {
        sessions.removeAll { $0.id == id }
        pendingPermissions.removeAll { $0.sessionID == id }
        pendingQuestions.removeAll { $0.sessionID == id }
        draftsBySession.removeValue(forKey: id)
        queuesBySession.removeValue(forKey: id)
        attachmentsBySession.removeValue(forKey: id)
        messagesCacheBySession.removeValue(forKey: id)
        lastSentPromptBySession.removeValue(forKey: id)
        sessionStatuses.removeValue(forKey: id)
        activeSessionIDs.remove(id)
        abortingSessionIDs.remove(id)
        retryInfoBySession.removeValue(forKey: id)
        inlineErrorsBySession.removeValue(forKey: id)
        unreadSessionIDs.remove(id)
        stopPolling(for: id)
        autoRetryCountBySession.removeValue(forKey: id)
        if pinnedSessionIDs.contains(id) {
            togglePinned(id, pinned: false)
        }
        modelsBySession.removeValue(forKey: id)
        variantsBySession.removeValue(forKey: id)
        AppSettings.sessionModels = modelsBySession
        AppSettings.sessionVariants = variantsBySession
        if selectedSessionID == id {
            selectedSessionID = nil
            messages = []
            isLoadingMessages = false
            todos = []
            autoSelectRecentSession()
        }
    }

    /// Aborts the current generation and cancels queued prompts — "stop"
    /// means stop everything.
    func abort(clearQueue: Bool = true) {
        guard let id = selectedSessionID else { return }
        Task { await performAbort(sessionID: id, clearQueue: clearQueue) }
    }

    /// Abort sequence the caller can wait for, so a follow-up prompt_async
    /// (e.g. "send queued prompt now") is not racing the server-side abort.
    private func performAbort(sessionID id: String, clearQueue: Bool, flushAfter: Bool = true) async {
        abortingSessionIDs.insert(id)
        retryInfoBySession.removeValue(forKey: id)
        if clearQueue {
            setQueue([], for: id)
        }
        guard let api else {
            finishRun(id)
            return
        }
        do {
            let _: EmptyResponse = try await api.post("session/\(id)/abort", body: nil)
        } catch {
            recordSessionFailure(id, message: error.localizedDescription)
        }
        finishRun(id)
        // The abort response means the server is idle again (or stopped on
        // its own); anything queued during the window can go out now.
        if flushAfter {
            flushQueue(for: id)
        }
    }

    func reply(to request: PermissionRequest, reply: String) {
        guard let api else { return }
        let body = ["response": reply]
        if reply == "always" {
            savePermissionRule(from: request)
        }
        Task {
            do {
                let _: EmptyResponse = try await api.post(
                    "session/\(request.sessionID)/permissions/\(request.id)",
                    body: try body.jsonData()
                )
                pendingPermissions.removeAll { $0.id == request.id }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func matchesSavedPermission(_ request: PermissionRequest) -> Bool {
        let kind = request.permission ?? ""
        let patterns = request.patterns ?? []
        if patterns.isEmpty {
            return savedPermissionRules.contains("\(kind)|")
        }
        return patterns.allSatisfy { pattern in
            savedPermissionRules.contains("\(kind)|\(pattern)")
        }
    }

    private func savePermissionRule(from request: PermissionRequest) {
        let kind = request.permission ?? ""
        let patterns = request.patterns ?? []
        let newRules = patterns.isEmpty
            ? ["\(kind)|"]
            : patterns.map { "\(kind)|\($0)" }
        var rules = savedPermissionRules
        for rule in newRules where !rules.contains(rule) {
            rules.append(rule)
        }
        savedPermissionRules = rules
        AppSettings.savedPermissionRules = rules
    }

    /// Per-session fallback snapshot refresh. The SSE stream remains the
    /// primary source of truth; this only keeps the visible transcript honest
    /// while its session still has an active run.
    private func startFallbackPolling(for sessionID: String) {
        stopPolling(for: sessionID)
        pollTasksBySession[sessionID] = Task { [weak self] in
            // No hard iteration cap: finishRun cancels the loop when the run
            // ends, so very long generations keep their fallback refresh.
            while !Task.isCancelled {
                // The SSE stream normally carries every update; only hit the
                // API while reconnecting (fast tick) or when output stalled
                // (slow tick). Healthy streaming stays fully silent.
                let reconnecting = self?.isReconnecting ?? false
                try? await Task.sleep(nanoseconds: reconnecting ? 2_000_000_000 : 6_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.activeSessionIDs.contains(sessionID) else { return }
                let stalled = Date().timeIntervalSince(self.lastStreamActivity) > 45
                if (reconnecting || stalled), sessionID == self.selectedSessionID {
                    await self.loadMessages()
                }
            }
        }
    }

    private func stopPolling(for sessionID: String) {
        pollTasksBySession[sessionID]?.cancel()
        pollTasksBySession.removeValue(forKey: sessionID)
    }

    private func finishRun(_ sessionID: String) {
        activeSessionIDs.remove(sessionID)
        abortingSessionIDs.remove(sessionID)
        retryInfoBySession.removeValue(forKey: sessionID)
        stopPolling(for: sessionID)
    }

    private func refreshMessagesIfSelected(_ sessionID: String) async {
        guard sessionID == selectedSessionID else { return }
        await loadMessages()
    }

    private func recordSessionFailure(_ sessionID: String, message: String, kind: FailureKind? = nil) {
        let error = InlineError(
            sessionID: sessionID,
            message: message,
            kind: kind ?? FailureKind.classify(message)
        )
        inlineErrorsBySession[sessionID] = error
    }

    /// Network-class send failures get exactly one automatic retry after a
    /// short backoff — transient connection resets recover on their own, and
    /// the ActivityBar shows progress via retryInfo. Anything else, a second
    /// failure, or a missing snapshot surfaces the inline error as before.
    private func maybeAutoRetry(_ sessionID: String, kind: FailureKind, message: String) {
        guard kind == .network,
              (autoRetryCountBySession[sessionID] ?? 0) < 1 else {
            recordSessionFailure(sessionID, message: message, kind: kind)
            return
        }
        autoRetryCountBySession[sessionID] = 1
        retryInfoBySession[sessionID] = NSLocalizedString(
            "Network error — retrying…", comment: ""
        )
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.retryInfoBySession.removeValue(forKey: sessionID)
            guard let prompt = self.lastSentPromptBySession[sessionID],
                  !self.abortingSessionIDs.contains(sessionID),
                  self.performSend(prompt, sessionID: sessionID) else {
                self.recordSessionFailure(sessionID, message: message, kind: kind)
                return
            }
        }
    }

    private func scheduleReconnect() {
        guard api != nil else { return }
        isReconnecting = true
        reconnectAttempts += 1
        // Exponential backoff: 1s, 2s, 4s, 8s, capped at 16s.
        let delay = min(pow(2.0, Double(min(reconnectAttempts - 1, 4))), 16.0)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, let api = self.api else { return }
            self.eventStream.connect(baseURL: api.baseURL)
        }
    }

    /// Routes one server event. Internal so tests can drive the pipeline.
    func handle(_ event: DevEvent) {
        switch event.type {
        case "server.connected":
            reconnectAttempts = 0
            isReconnecting = false
            Task { await refresh() }
            Task { await loadMessages() }
            Task { await loadBranch() }
            Task { await loadUsage() }
            Task { await loadCommands() }
            Task { await loadAgreement() }
        case "session.created", "session.updated":
            guard let info = event.object("info"), let session: Session = decode(.object(info)) else { return }
            upsert(session)
        case "session.deleted":
            if let id = event.property("sessionID") {
                applyDeletion(of: id)
            }
        case "session.idle":
            guard let sessionID = event.property("sessionID") else {
                Task { await loadUsage() }
                return
            }
            let wasGenerating = activeSessionIDs.contains(sessionID)
                || (sessionStatuses[sessionID].map { $0 != "idle" } ?? false)
            sessionStatuses[sessionID] = "idle"
            activeSessionIDs.remove(sessionID)
            retryInfoBySession.removeValue(forKey: sessionID)
            stopPolling(for: sessionID)
            if sessionID == selectedSessionID {
                flushDeltas()
            }
            // During an explicit abort, wait for the abort response before
            // draining the queue so prompt_async cannot race the server.
            if !abortingSessionIDs.contains(sessionID) {
                flushQueue(for: sessionID)
            }
            if wasGenerating {
                notifyCompletion(sessionID: sessionID)
            }
            // 后台会话的 SSE 增量被 upsert/append 的 selectedSessionID 守卫
            // 丢弃；空闲时抓一次快照存入缓存，切回时立即可见完整转写。
            if sessionID != selectedSessionID {
                Task { [weak self] in
                    await self?.loadMessages(for: sessionID)
                }
            }
            markUnreadIfNeeded(sessionID, wasGenerating: wasGenerating)
            Task { await loadUsage() }
        case "session.status":
            guard let sessionID = event.property("sessionID") else { return }
            let status = event.object("status")
            let statusType = status?["type"]?.stringValue ?? event.property("status")
            let wasGenerating = activeSessionIDs.contains(sessionID)
                || (sessionStatuses[sessionID].map { $0 != "idle" } ?? false)
            sessionStatuses[sessionID] = statusType
            if statusType == "idle" {
                activeSessionIDs.remove(sessionID)
                retryInfoBySession.removeValue(forKey: sessionID)
                stopPolling(for: sessionID)
                if sessionID == selectedSessionID {
                    flushDeltas()
                }
                if !abortingSessionIDs.contains(sessionID) {
                    flushQueue(for: sessionID)
                }
                markUnreadIfNeeded(sessionID, wasGenerating: wasGenerating)
                if sessionID == selectedSessionID {
                    Task { await loadUsage() }
                }
            } else if statusType == "retry" {
                // Schema: {type: "retry", attempt, message} — keep the
                // generating state and surface the reason.
                activeSessionIDs.insert(sessionID)
                let attempt = status?["attempt"]?.intValue
                let message = status?["message"]?.stringValue
                let info = [attempt.map { "attempt \($0)" }, message]
                    .compactMap { $0 }.joined(separator: " · ")
                if info.isEmpty {
                    retryInfoBySession.removeValue(forKey: sessionID)
                } else {
                    retryInfoBySession[sessionID] = info
                }
            } else if statusType == "busy" {
                activeSessionIDs.insert(sessionID)
                retryInfoBySession.removeValue(forKey: sessionID)
            }
        case "message.updated":
            guard let info = event.object("info"),
                  let sessionID = event.property("sessionID"),
                  let infoRecord: MessageInfo = decode(.object(info)) else { return }
            upsert(infoRecord, in: sessionID)
        case "message.part.updated":
            guard let partObject = event.object("part"),
                  let sessionID = event.property("sessionID"),
                  let part: Part = decode(.object(partObject)),
                  let messageID = partObject["messageID"]?.displayText else { return }
            // The server's part supersedes any buffered deltas for it.
            pendingDeltas.removeValue(forKey: part.id)
            lastStreamActivity = Date()
            upsert(part, messageID: messageID, in: sessionID)
        case "message.part.delta":
            guard let sessionID = event.property("sessionID"),
                  let messageID = event.property("messageID"),
                  let partID = event.property("partID"),
                  let delta = event.property("delta") else { return }
            // The delta names the part field it modifies; only append text.
            // (Older servers omitted `field`, so treat nil as text too.)
            let field = event.property("field") ?? "text"
            guard field == "text" else { return }
            append(delta, to: partID, in: messageID, sessionID: sessionID)
        case "permission.asked", "permission.v2.asked":
            guard let properties = event.properties,
                  let request: PermissionRequest = decode(properties) else { return }
            // A saved rule ("permission|pattern") approves the request without
            // surfacing the banner; otherwise the user decides.
            if matchesSavedPermission(request) {
                reply(to: request, reply: "once")
                return
            }
            if !pendingPermissions.contains(where: { $0.id == request.id }) {
                pendingPermissions.append(request)
                schedulePermissionNotification()
            }
        case "permission.replied", "permission.v2.replied":
            // Different deveco builds report the id under different keys.
            let replyID = event.property("requestID") ?? event.property("permissionID")
                ?? event.property("id")
            if let replyID {
                pendingPermissions.removeAll { $0.id == replyID }
            }
        case "question.asked", "question.v2.asked":
            guard let properties = event.properties,
                  let request: UserQuestionRequest = decode(properties) else { return }
            if !pendingQuestions.contains(where: { $0.id == request.id }) {
                pendingQuestions.append(request)
            }
        case "question.replied", "question.v2.replied",
             "question.rejected", "question.v2.rejected":
            if let id = event.property("requestID") {
                pendingQuestions.removeAll { $0.id == id }
            }
        case "vcs.branch.updated":
            vcsBranch = event.property("branch")
        case "installation.update-available":
            updateAvailable = true
        case "session.error":
            // Schema: error is {name, data:{message, ...}} — the official web
            // client reads data.message; keep the string form as a fallback.
            var consentGate = false
            var errorText = ""
            if let error = event.object("error") {
                let name = error["name"]?.stringValue
                let message = error["data"]?.objectValue?["message"]?.stringValue
                errorText = [name, message].compactMap { $0 }.joined(separator: ": ")
                if let message, message.lowercased().contains("product agreement") || message.contains("auth consent") {
                    consentGate = true
                }
            } else if let message = event.property("error") {
                errorText = message
                if message.lowercased().contains("product agreement") || message.contains("auth consent") {
                    consentGate = true
                }
            }
            if consentGate {
                needsConsent = true
                Task { await loadAgreement() }
            } else if !errorText.isEmpty {
                // Session-scoped errors show inline in the conversation; server
                // level ones stay in the global banner. Both get a failure
                // category so the UI can suggest the next step.
                let kind = FailureKind.classify(errorText)
                if let sessionID = event.property("sessionID") {
                    finishRun(sessionID)
                    maybeAutoRetry(sessionID, kind: kind, message: errorText)
                } else {
                    errorMessage = kind.label + ": " + errorText
                }
            }
        case "todo.updated":
            guard event.property("sessionID") == selectedSessionID,
                  let properties = event.properties,
                  let todosValue = properties.objectValue?["todos"] else { return }
            todos = decode(.array(todosValue.arrayValue ?? [])) ?? todos
        case "session.diff":
            guard event.property("sessionID") == selectedSessionID,
                  let properties = event.properties,
                  let diffValue = properties.objectValue?["diff"] else { return }
            diffs = decode(.array(diffValue.arrayValue ?? [])) ?? diffs
        case "message.removed":
            guard sessionIDMatches(event), let messageID = event.property("messageID") else { return }
            messages.removeAll { $0.id == messageID }
        case "message.part.removed":
            guard sessionIDMatches(event), let messageID = event.property("messageID"),
                  let partID = event.property("partID") else { return }
            if let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].parts.removeAll { $0.id == partID }
            }
        default:
            break
        }
    }

    /// Posts a system notification and plays a sound when a session finishes
    /// generating — only for background sessions, like a mature chat client.
    private func notifyCompletion(sessionID: String?) {
        if AppSettings.playSoundOnComplete {
            NSSound(named: "Glass")?.play()
        }
        guard AppSettings.notifyOnComplete, !NSApp.isActive else { return }
        let title = sessions.first { $0.id == sessionID }?.displayTitle
            ?? NSLocalizedString("Session", comment: "")
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Generation finished", comment: "")
        content.body = String(
            format: NSLocalizedString("“%@” finished generating.", comment: ""),
            title
        )
        if let sessionID {
            content.userInfo = ["sessionID": sessionID]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A background run that reached idle is "new activity" until the user
    /// opens that conversation. If a queued prompt immediately started a new
    /// run, leave the session in busy state instead.
    private func markUnreadIfNeeded(_ sessionID: String, wasGenerating: Bool) {
        guard wasGenerating,
              sessionID != selectedSessionID,
              !activeSessionIDs.contains(sessionID) else { return }
        unreadSessionIDs.insert(sessionID)
    }

    /// If a permission request sits unanswered for 10s while the app is in
    /// the background, nudge with a notification (generation is blocked).
    /// Each request nudges at most once, even while others are still pending.
    private var notifiedPermissionIDs: Set<String> = []

    private func schedulePermissionNotification() {
        guard AppSettings.notifyOnComplete else { return }
        guard let request = pendingPermissions.last,
              !notifiedPermissionIDs.contains(request.id) else { return }
        notifiedPermissionIDs.insert(request.id)
        let tool = request.title
        let permissionSessionID = request.sessionID
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard pendingPermissions.contains(where: { $0.id == request.id }),
                  !NSApp.isActive else { return }
            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("Permission needed", comment: "")
            content.body = tool
            content.userInfo = ["sessionID": permissionSessionID]
            let request = UNNotificationRequest(identifier: "permission-\(UUID().uuidString)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func decode<T: Decodable>(_ value: JSONValue) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder.deveco.decode(T.self, from: data)
    }

    private func sessionIDMatches(_ event: DevEvent) -> Bool {
        event.property("sessionID") == selectedSessionID
    }

    private func decodePart(_ object: [String: JSONValue]) -> Part? {
        decode(.object(object))
    }

    private func upsert(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    private func upsert(_ info: MessageInfo, in sessionID: String) {
        guard sessionID == selectedSessionID else { return }
        if let index = messages.firstIndex(where: { $0.id == info.id }) {
            messages[index].info = info
        } else {
            messages.append(MessageRecord(info: info, parts: []))
            streamTick += 1
        }
    }

    private func upsert(_ part: Part, messageID: String, in sessionID: String) {
        guard sessionID == selectedSessionID else { return }
        if let messageIndex = messages.firstIndex(where: { $0.id == messageID }) {
            if let partIndex = messages[messageIndex].parts.firstIndex(where: { $0.id == part.id }) {
                messages[messageIndex].parts[partIndex] = part
            } else {
                messages[messageIndex].parts.append(part)
            }
        } else {
            messages.append(
                MessageRecord(
                    info: MessageInfo(id: messageID, role: "assistant", modelID: nil, providerID: nil),
                    parts: [part]
                )
            )
        }
        streamTick += 1
    }

    /// Buffers streaming deltas and flushes them to the published transcript
    /// at most every ~120ms — one published mutation per burst instead of per
    /// character keeps long streams smooth.
    private func append(_ delta: String, to partID: String, in messageID: String, sessionID: String) {
        guard sessionID == selectedSessionID else { return }
        lastStreamActivity = Date()
        pendingDeltas[partID, default: ""] += delta
        let buffered = pendingDeltas[partID]?.count ?? 0
        if Date().timeIntervalSince(lastDeltaFlush) >= 0.12 || buffered > 8_192 {
            flushDeltas()
        }
    }

    private func flushDeltas() {
        guard !pendingDeltas.isEmpty else { return }
        var mutated = false
        var unresolved: [String: String] = [:]
        for (partID, delta) in pendingDeltas {
            if let messageIndex = messages.firstIndex(where: { $0.parts.contains { $0.id == partID } }),
               let partIndex = messages[messageIndex].parts.firstIndex(where: { $0.id == partID }) {
                messages[messageIndex].parts[partIndex].text = (messages[messageIndex].parts[partIndex].text ?? "") + delta
                mutated = true
            } else {
                // The part hasn't been created yet; keep its deltas buffered.
                unresolved[partID] = (unresolved[partID] ?? "") + delta
            }
        }
        pendingDeltas = unresolved
        lastDeltaFlush = Date()
        if mutated {
            lastStreamActivity = Date()
            streamTick += 1
        }
    }

    /// Re-sends the last prompt of the selected session (inline error Retry).
    func retryLastPrompt() {
        guard let id = selectedSessionID, let prompt = lastSentPromptBySession[id] else { return }
        inlineErrorsBySession.removeValue(forKey: id)
        if isSending {
            enqueue(QueuedPrompt(prompt: prompt), for: id)
            return
        }
        if !performSend(prompt, sessionID: id) {
            enqueue(QueuedPrompt(prompt: prompt), for: id)
        }
    }
}
