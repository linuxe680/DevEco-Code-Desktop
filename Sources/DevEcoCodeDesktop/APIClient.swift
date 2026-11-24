import Foundation
import os

extension JSONDecoder {
    /// A fresh decoder per call: `JSONDecoder` is a class with mutable decode
    /// state and is not thread-safe. The SSE reader decodes on the main
    /// thread while `APIClient`/`ProviderStore` decode concurrently on task
    /// threads, so a shared instance can corrupt in-flight parses.
    static var deveco: JSONDecoder { JSONDecoder() }
}

final class APIClient {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await send("GET", url(for: path, query: query), body: nil)
        return try JSONDecoder.deveco.decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, body: Data?) async throws -> T {
        let data = try await send("POST", url(for: path), body: body)
        return try JSONDecoder.deveco.decode(T.self, from: data)
    }

    func patch<T: Decodable>(_ path: String, body: Data?) async throws -> T {
        let data = try await send("PATCH", url(for: path), body: body)
        return try JSONDecoder.deveco.decode(T.self, from: data)
    }

    func delete(_ path: String) async throws {
        _ = try await send("DELETE", url(for: path), body: nil)
    }

    /// POST whose response body is discarded (unrevert, compact, replies).
    func postNoContent(_ path: String, body: Data? = nil) async throws {
        _ = try await send("POST", url(for: path), body: body)
    }

    private func url(for path: String, query: [String: String] = [:]) -> URL {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            if let withQuery = components?.url {
                url = withQuery
            }
        }
        return url
    }

    private func send(_ method: String, _ url: URL, body: Data?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        // 仅 GET 是幂等的，才可安全自动重试。写请求（POST/PATCH/DELETE）
        // 若服务端已提交但响应丢失，重试会重复发送消息/创建会话——
        // 这类错误交给上层 inlineError + Retry 由用户显式决定。
        let maxAttempts = method == "GET" ? 2 : 1

        var lastError: Error = APIError.invalidResponse
        var attempt = 0
        while attempt < maxAttempts {
            attempt += 1
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    let error = APIError.status(http.statusCode, String(text.prefix(300)))
                    if http.statusCode >= 500, attempt < maxAttempts {
                        lastError = error
                        Log.network.warning("HTTP \(http.statusCode) from \(url.path, privacy: .public) — retrying once")
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        continue
                    }
                    throw error
                }
                return data.isEmpty ? Data("{}".utf8) : data
            } catch let urlError as URLError
                where attempt < maxAttempts && Self.retriableErrorCodes.contains(urlError.code) {
                lastError = urlError
                Log.network.warning("\(urlError.code.rawValue, privacy: .public) on \(url.path, privacy: .public) — retrying once")
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        throw lastError
    }

    private static let retriableErrorCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]
}

struct EmptyResponse: Decodable {}

extension Encodable {
    func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
