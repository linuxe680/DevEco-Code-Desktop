import Foundation
import Combine

extension Notification.Name {
    /// 服务端 "Always allow" 规则变更后发出，SessionStore 据此刷新本地缓存。
    static let savedPermissionsDidChange = Notification.Name("savedPermissionsDidChange")
}

@MainActor
final class ProviderStore: ObservableObject {
    @Published var providers: [ProviderEntry] = [] {
        didSet {
            // Compare full entries, not just ids: renaming a provider model
            // keeps the id list identical, but the cached display names used
            // by message metadata would stay stale.
            if providers != oldValue { rebuildModelLookup() }
        }
    }
    @Published var catalog: [CatalogProvider] = []
    @Published var defaultModel = ""
    @Published var errorMessage: String?
    @Published var isSaving = false
    /// Every runnable model from GET /api/model (built-ins + configured).
    @Published private(set) var serverModels: [ServerModel] = []
    /// Cached model list for pickers and hot-path lookups; rebuilt only when
    /// serverModels/providers change (was rebuilt+sorted on every access).
    @Published private(set) var allModelChoices: [ModelChoice] = []
    /// O(1) display-name lookup for message metadata (rebuilt on load).
    private var modelChoicesByID: [String: ModelChoice] = [:]
    private var modelNameBySuffix: [String: String] = [:]
    /// Normalized catalog ids used when the server reports a slightly
    /// different id (vendor suffix differences).
    private var modelNameByLooseID: [(key: String, name: String)] = []
    /// Memoizes the substring fallback below; the model-id set is small but
    /// this lookup runs for every streamed message's metadata.
    /// Misses are cached too — a plain `[String: String?]` would drop the key
    /// when storing `nil` and rescan every model on each streamed message.
    private enum FuzzyNameLookup {
        case miss
        case hit(String)
    }
    private var fuzzyNameCache: [String: FuzzyNameLookup] = [:]
    /// In-flight `load()` calls are generation-tagged. A save/delete followed
    /// by `load()` must not be overwritten by an older fetch already running
    /// (load fetches config/catalog/models in parallel).
    private var loadGeneration = 0

    private func rebuildModelLookup() {
        fuzzyNameCache.removeAll()
        var lookup: [String: ModelChoice] = [:]
        var seen = Set<String>()
        var choices: [ModelChoice] = []
        for model in serverModels {
            let providerID = model.providerID ?? "unknown"
            let id = "\(providerID)/\(model.id)"
            guard seen.insert(id).inserted else { continue }
            let choice = ModelChoice(id: id, provider: providerID, name: model.name ?? model.id)
            choices.append(choice)
            lookup[id] = choice
        }
        for provider in providers {
            for model in provider.models {
                let id = "\(provider.id)/\(model.id)"
                guard seen.insert(id).inserted else { continue }
                let choice = ModelChoice(id: id, provider: provider.id, name: model.name)
                choices.append(choice)
                lookup[id] = choice
            }
        }
        let sorted = choices.sorted { ($0.provider, $0.name) < ($1.provider, $1.name) }
        allModelChoices = sorted
        for choice in sorted {
            lookup[choice.id] = choice
        }
        modelChoicesByID = lookup
        var namesBySuffix: [String: String] = [:]
        var loose: [(key: String, name: String)] = []
        for choice in sorted {
            // choice.id 形如 "providerID/modelID"；按 modelID 建索引，
            // 不能用展示名，展示名常与 ID 不同。
            guard let slash = choice.id.firstIndex(of: "/") else { continue }
            let modelID = String(choice.id[choice.id.index(after: slash)...])
            if namesBySuffix[modelID] == nil { namesBySuffix[modelID] = choice.name }
            loose.append((normalizedModelKey(choice.id), choice.name))
        }
        modelNameByLooseID = loose
        modelNameBySuffix = namesBySuffix
    }

    /// Display name for a "providerID/modelID" identifier; falls back to a
    /// fuzzy match on the bare model id. Hot path during streaming.
    func modelDisplayName(for identifier: String, fuzzyModel: String) -> String? {
        if let choice = modelChoicesByID[identifier] { return choice.name }
        if let exact = modelNameBySuffix[fuzzyModel] { return exact }
        // Server-reported ids can carry a vendor suffix the catalog spells out
        // (`hy4flash` vs `hy4flash-free`). Accept a unique prefix match only,
        // so a base id never resolves to its `-max` sibling.
        if let loose = uniqueCatalogModelName(for: identifier, in: modelNameByLooseID) {
            return loose
        }
        if let cached = fuzzyNameCache[fuzzyModel] {
            switch cached {
            case .miss: return nil
            case .hit(let name): return name
            }
        }
        let match = modelChoicesByID.values
            .first { $0.name.localizedCaseInsensitiveContains(fuzzyModel) }?.name
        fuzzyNameCache[fuzzyModel] = match.map(FuzzyNameLookup.hit) ?? .miss
        return match
    }
    /// "Always allow" rules saved via permission cards; revocable.
    @Published private(set) var savedPermissions: [SavedPermission] = []

    private var api: APIClient?
    private var rawConfig: [String: JSONValue] = [:]
    private var loadTask: Task<Void, Never>?

    /// Variant ids (e.g. reasoning effort) available for the given model.
    func variants(for modelID: String?) -> [String] {
        guard let modelID else { return [] }
        let pieces = modelID.split(separator: "/", maxSplits: 1)
        guard pieces.count == 2 else { return [] }
        let provider = String(pieces[0])
        let id = String(pieces[1])
        let model = serverModels.first { $0.providerID == provider && $0.id == id }
        return (model?.variants ?? []).map(\.id)
    }

    /// Context window (tokens) of the given "providerID/modelID" selection.
    func contextLimit(for modelID: String?) -> Double? {
        guard let modelID else { return nil }
        let pieces = modelID.split(separator: "/", maxSplits: 1)
        guard pieces.count == 2 else { return nil }
        let provider = String(pieces[0])
        let id = String(pieces[1])
        return serverModels.first { $0.providerID == provider && $0.id == id }?.limit?.context
    }

    func loadSavedPermissions() async {
        guard let api else { return }
        do {
            let response: SavedPermissionResponse = try await api.get("api/permission/saved")
            savedPermissions = response.data ?? []
            // 服务端是"Always allow"规则的唯一真相：用服务端列表覆盖客户端缓存，
            // 避免用户在设置页撤销后客户端仍按旧规则自动放行。
            let rules = savedPermissions.compactMap { saved -> String? in
                let action = saved.action ?? ""
                let resource = saved.resource ?? ""
                if action.isEmpty { return nil }
                return resource.isEmpty ? "\(action)|" : "\(action)|\(resource)"
            }
            AppSettings.savedPermissionRules = rules
            NotificationCenter.default.post(name: .savedPermissionsDidChange, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Revokes an "Always allow" rule.
    func deleteSavedPermission(_ saved: SavedPermission) async {
        guard let api else { return }
        do {
            try await api.delete("api/permission/saved/\(saved.id)")
            await loadSavedPermissions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connect(baseURL: URL) {
        if let api, api.baseURL == baseURL, loadTask != nil { return }
        api = APIClient(baseURL: baseURL)
        loadGeneration &+= 1
        loadTask = Task { [weak self] in
            await self?.load()
            self?.loadTask = nil
        }
    }

    func disconnect() {
        api = nil
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        providers = []
        catalog = []
        rawConfig = [:]
        errorMessage = nil
        serverModels = []
        defaultModel = ""
        rebuildModelLookup()
    }

    func load() async {
        guard let api else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        async let configFetch: JSONValue = api.get("config")
        async let catalogFetch: CatalogResponse = api.get("provider")
        async let modelsFetch: ModelListResponse = api.get("api/model")
        do {
            let config = try await configFetch
            guard generation == loadGeneration, api === self.api else { return }
            rawConfig = config.objectValue ?? [:]
            defaultModel = rawConfig["model"]?.stringValue ?? ""
            let providerObjects = rawConfig["provider"]?.objectValue ?? [:]
            providers = providerObjects.compactMap { ProviderEntry.parse(id: $0.key, value: $0.value) }
                .sorted { $0.id < $1.id }
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            let response = try await catalogFetch
            guard generation == loadGeneration, api === self.api else { return }
            catalog = response.all.sorted { $0.displayName < $1.displayName }
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            let models = try await modelsFetch.data ?? []
            guard generation == loadGeneration, api === self.api else { return }
            serverModels = models
        } catch {
            // Model list is decoration for the picker; keep quiet on failure.
        }
        rebuildModelLookup()
    }

    func modelChoices(for providerID: String) -> [ModelEntry] {
        providers.first { $0.id == providerID }?.models ?? []
    }

    func providerFromCatalog(_ item: CatalogProvider) -> ProviderEntry? {
        let object: [String: JSONValue] = [
            "name": .string(item.displayName),
            "npm": .string("@ai-sdk/openai-compatible"),
            "options": .object([:]),
            "models": .object(item.models ?? [:]),
        ]
        return ProviderEntry.parse(id: item.id, value: .object(object))
    }

    func save(_ provider: ProviderEntry) async -> Bool {
        guard let api else { return false }
        isSaving = true
        defer { isSaving = false }
        var providerObjects = rawConfig["provider"]?.objectValue ?? [:]
        providerObjects[provider.id] = provider.jsonValue()
        do {
            let body = ["provider": JSONValue.object(providerObjects)]
            let _: JSONValue = try await api.patch("config", body: body.jsonData())
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Picks a still-runnable default when the provider holding the current
    /// default is removed. `nil` means the default is unaffected; `""` means
    /// clear it. Testable without a live server.
    nonisolated static func replacementDefaultModel(
        current: String,
        deletedProviderID: String,
        availableModels: [ServerModel],
        clientDefault: String = AppSettings.defaultSessionModel
    ) -> String? {
        // The client-side default is independent of the server's configured
        // model. Deleting a provider must not silently repoint new sessions
        // to a model the user never chose for this app; use a runnable server
        // model instead and let the Settings picker stay untouched.
        return replacementDefaultModel(
            current: current,
            deletedProviderID: deletedProviderID,
            availableModels: availableModels,
            fallbackClientDefault: nil
        )
    }

    nonisolated private static func replacementDefaultModel(
        current: String,
        deletedProviderID: String,
        availableModels: [ServerModel],
        fallbackClientDefault: String?
    ) -> String? {
        guard !deletedProviderID.isEmpty,
              current.hasPrefix(deletedProviderID + "/") else { return nil }
        let candidates = (fallbackClientDefault.map { [$0] } ?? []) + availableModels.compactMap { model -> String? in
            guard let providerID = model.providerID else { return nil }
            return "\(providerID)/\(model.id)"
        }
        return candidates.first {
            !$0.isEmpty && !$0.hasPrefix(deletedProviderID + "/")
        } ?? ""
    }

    func delete(_ provider: ProviderEntry) async {
        guard let api else { return }
        var providerObjects = rawConfig["provider"]?.objectValue ?? [:]
        providerObjects.removeValue(forKey: provider.id)
        var body: [String: JSONValue] = ["provider": JSONValue.object(providerObjects)]
        let previousDefault = defaultModel
        if let replacement = Self.replacementDefaultModel(
            current: previousDefault,
            deletedProviderID: provider.id,
            availableModels: serverModels
        ) {
            // Send the model change in the SAME patch. Clearing only the local
            // value used to be undone by load(), which read the stale server
            // config back and re-selected a model from the deleted provider.
            body["model"] = .string(replacement)
            defaultModel = replacement
        }
        do {
            let _: JSONValue = try await api.patch("config", body: JSONValue.object(body).jsonData())
            await load()
        } catch {
            defaultModel = previousDefault
            errorMessage = error.localizedDescription
        }
    }

    func setDefaultModel(_ model: String) async {
        guard let api else { return }
        do {
            let body = ["model": JSONValue.string(model)]
            let _: JSONValue = try await api.patch("config", body: body.jsonData())
            defaultModel = model
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
