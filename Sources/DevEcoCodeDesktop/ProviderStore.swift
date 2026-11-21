import Foundation
import Combine

@MainActor
final class ProviderStore: ObservableObject {
    @Published var providers: [ProviderEntry] = []
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

    private func rebuildModelLookup() {
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
    }

    /// Display name for a "providerID/modelID" identifier; falls back to a
    /// fuzzy match on the bare model id. Hot path during streaming.
    func modelDisplayName(for identifier: String, fuzzyModel: String) -> String? {
        if let choice = modelChoicesByID[identifier] { return choice.name }
        return modelChoicesByID.values
            .first { $0.name.localizedCaseInsensitiveContains(fuzzyModel) }?.name
    }
    /// "Always allow" rules saved via permission cards; revocable.
    @Published private(set) var savedPermissions: [SavedPermission] = []

    private var api: APIClient?
    private var rawConfig: [String: JSONValue] = [:]

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
        api = APIClient(baseURL: baseURL)
        Task { await load() }
    }

    func disconnect() {
        api = nil
        providers = []
        catalog = []
        rawConfig = [:]
        errorMessage = nil
    }

    func load() async {
        guard let api else { return }
        async let configFetch: JSONValue = api.get("config")
        async let catalogFetch: CatalogResponse = api.get("provider")
        async let modelsFetch: ModelListResponse = api.get("api/model")
        do {
            let config = try await configFetch
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
            catalog = response.all.sorted { $0.displayName < $1.displayName }
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            serverModels = try await modelsFetch.data ?? []
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

    func delete(_ provider: ProviderEntry) async {
        guard let api else { return }
        var providerObjects = rawConfig["provider"]?.objectValue ?? [:]
        providerObjects.removeValue(forKey: provider.id)
        do {
            let body = ["provider": JSONValue.object(providerObjects)]
            let _: JSONValue = try await api.patch("config", body: body.jsonData())
            if defaultModel.hasPrefix(provider.id + "/") {
                defaultModel = ""
            }
            await load()
        } catch {
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
