import Foundation

@MainActor
final class ToolingStore: ObservableObject {
    @Published private(set) var skills: [SkillInfo] = []
    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var mcpStatus: [String: MCPStatus] = [:]
    @Published private(set) var capabilities = ExperimentalCapabilities(backgroundSubagents: nil)
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var api: APIClient?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var directory: String?
    private var workspace: String?

    func connect(baseURL: URL) {
        if let api, api.baseURL == baseURL, loadTask != nil { return }
        api = APIClient(baseURL: baseURL)
        Task { await load() }
    }

    func configureLocation(directory: String?, workspace: String?) {
        let changed = self.directory != directory || self.workspace != workspace
        self.directory = directory
        self.workspace = workspace
        guard changed, api != nil else { return }
        Task { await load() }
    }

    private var locationQuery: [String: String] {
        APIClient.locationQuery(directory: directory, workspace: workspace)
    }

    func disconnect() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        api = nil
        directory = nil
        workspace = nil
        skills = []
        agents = []
        mcpStatus = [:]
        capabilities = ExperimentalCapabilities(backgroundSubagents: nil)
        isLoading = false
        errorMessage = nil
    }

    func load() async {
        guard let api else { return }
        generation &+= 1
        let current = generation
        isLoading = true
        errorMessage = nil
        let query = locationQuery
        async let skillsFetch: SkillListResponse = api.get("api/skill", query: query)
        async let agentsFetch: AgentListResponse = api.get("api/agent", query: query)
        async let mcpFetch: [String: MCPStatus] = api.get("mcp")
        async let capabilitiesFetch: ExperimentalCapabilities = api.get("experimental/capabilities")
        do {
            let loadedSkills = try await skillsFetch.data
            let loadedAgents = try await agentsFetch.data
            let loadedMCP = try await mcpFetch
            let loadedCapabilities = try await capabilitiesFetch
            guard current == generation else { return }
            skills = loadedSkills
            agents = loadedAgents
            mcpStatus = loadedMCP
            capabilities = loadedCapabilities
            isLoading = false
        } catch {
            guard current == generation else { return }
            errorMessage = UserFacingError.message(error)
            isLoading = false
        }
    }

    func connectMCP(_ name: String) async {
        await mutateMCP(name) { api, query in
            _ = try await api.post("mcp/\(name)/connect", query: query, body: nil) as Bool
        }
    }

    func disconnectMCP(_ name: String) async {
        await mutateMCP(name) { api, query in
            _ = try await api.post("mcp/\(name)/disconnect", query: query, body: nil) as Bool
        }
    }

    private func mutateMCP(
        _ name: String,
        operation: (APIClient, [String: String]) async throws -> Void
    ) async {
        guard let api else { return }
        errorMessage = nil
        do {
            try await operation(api, locationQuery)
            await load()
        } catch {
            errorMessage = UserFacingError.message(error)
        }
    }
}
