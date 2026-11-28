import Foundation

struct SkillInfo: Decodable, Identifiable, Equatable {
    let name: String
    let description: String?
    let slash: Bool?
    let location: String
    let content: String

    var id: String { "\(location)/\(name)" }
}

struct SkillListResponse: Decodable {
    let data: [SkillInfo]
}

struct AgentModelInfo: Decodable, Equatable {
    let id: String
    let providerID: String
    let variant: String?
}

struct AgentInfo: Decodable, Identifiable, Equatable {
    let id: String
    let model: AgentModelInfo?
    let description: String?
    let system: String?
    let mode: String?
    let hidden: Bool?
    let color: String?
    let steps: Int?
}

struct AgentListResponse: Decodable {
    let data: [AgentInfo]
}

enum MCPStatus: Decodable, Equatable {
    case connected
    case disabled
    case failed(String)
    case needsAuth
    case needsClientRegistration(String)
    case unknown(String)

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .disabled: return "Disabled"
        case .failed: return "Failed"
        case .needsAuth: return "Needs authentication"
        case .needsClientRegistration: return "Needs client registration"
        case .unknown(let status): return status
        }
    }

    var detail: String? {
        switch self {
        case .failed(let message), .needsClientRegistration(let message): return message
        default: return nil
        }
    }

    var canConnect: Bool {
        switch self {
        case .connected, .needsAuth, .needsClientRegistration: return false
        default: return true
        }
    }

    var canDisconnect: Bool {
        if case .connected = self { return true }
        return false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        let error = try container.decodeIfPresent(String.self, forKey: .error)
        switch status {
        case "connected": self = .connected
        case "disabled": self = .disabled
        case "failed": self = .failed(error ?? "")
        case "needs_auth": self = .needsAuth
        case "needs_client_registration": self = .needsClientRegistration(error ?? "")
        default: self = .unknown(status.isEmpty ? "Unknown" : status)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case status, error
    }
}

struct MCPConfig: Encodable {
    let name: String
    let config: JSONValue
}

struct VcsStatus: Decodable, Identifiable, Equatable {
    let file: String
    let additions: Double
    let deletions: Double
    let status: String

    var id: String { file }
}

struct VcsDiff: Decodable, Identifiable, Equatable {
    let file: String
    let patch: String?
    let additions: Double?
    let deletions: Double?
    let status: String?

    var id: String { file }
}

struct VcsApplyResponse: Decodable {
    let applied: Bool
}

struct FileSystemEntry: Decodable, Identifiable, Equatable {
    let path: String
    let type: String
    let mime: String

    var id: String { path }
    var isDirectory: Bool { type == "directory" }
}

struct FileListResponse: Decodable {
    let data: [FileSystemEntry]
}

struct ReferenceInfo: Decodable, Identifiable, Equatable {
    let name: String
    let path: String
    let description: String?
    let hidden: Bool?
    let source: JSONValue?

    var id: String { path }
}

struct ReferenceListResponse: Decodable {
    let data: [ReferenceInfo]
}

struct ExperimentalCapabilities: Decodable, Equatable {
    let backgroundSubagents: Bool?
}

struct MCPAddRequest: Encodable {
    let name: String
    let config: JSONValue
}

struct SessionShare: Decodable, Equatable {
    let url: String?
}

struct SessionShareInfo: Codable, Equatable {
    let url: String?
}

struct VcsApplyRequest: Encodable {
    let patch: String
}

struct SessionSummarizeRequest: Encodable {
    let providerID: String
    let modelID: String
    let auto: Bool?
}
