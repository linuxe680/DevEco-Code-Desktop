import Foundation
import os

/// Consumes the server's `GET /event` SSE stream.
///
/// Frames are buffered as `Data` and only converted to `String` once complete:
/// converting each network chunk separately would corrupt multi-byte UTF-8
/// characters (e.g. CJK text) split across chunk boundaries.
final class EventStream: NSObject, URLSessionDataDelegate {
    var onEvent: ((DevEvent) -> Void)?
    var onDisconnect: (() -> Void)?
    /// Fired when the socket has been silent long enough to look dead.
    var onStalled: (() -> Void)?
    /// Fired when the server answers the SSE request with a fatal HTTP
    /// response. The caller must stop reconnecting and show a diagnosis —
    /// silently retrying a 401/404 forever leaves the UI stuck with no cause.
    var onFatalResponse: ((Int?, String) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    /// Bytes already scanned with no terminator found. Keeps long, fragmented
    /// frames from being rescanned from byte zero on every network chunk.
    private var scanOffset = 0
    private var lastReceiveDate: Date?
    /// When the current socket opened. A server that accepts the connection
    /// but never sends a single byte must still trip the stall guard.
    private var connectedAt: Date?
    private var stalledCheck: DispatchSourceTimer?
    /// Set when the server answers the SSE request with something other than a
    /// 200 event-stream (401/404, an HTML error page, a proxy interstitial).
    private(set) var lastHTTPStatus: Int?

    /// 连续解码失败计数。服务端事件格式变更或密钥轮换时，
    /// 静默丢帧会让 UI 永远停在旧状态——需要显式告警。
    private var consecutiveDecodeFailures = 0
    private static let failureWarningThreshold = 5

    /// True once any SSE byte (including `: keepalive` comments) has arrived.
    /// The UI uses this to distinguish "connected but thinking" from a dead
    /// socket instead of appearing frozen with no explanation.
    private(set) var isReceivingHeartbeats = false

    /// Whether a live SSE task exists. Used by SessionStore.connect to avoid
    /// tearing down and rebuilding the stream when SwiftUI re-emits the same
    /// baseURL after an unrelated ServerManager state change.
    var isConnected: Bool { task != nil }

    fileprivate static func makeStalledCheckTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        return timer
    }

    override init() {
        super.init()
    }

    private func ensureStalledCheck() {
        guard stalledCheck == nil else { return }
        let timer = Self.makeStalledCheckTimer()
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.task != nil,
                  self.heartbeatIsStale() else { return }
            Log.stream.warning("SSE heartbeat stalled — forcing reconnect")
            self.onStalled?()
        }
        timer.resume()
        stalledCheck = timer
    }

    deinit {
        stalledCheck?.cancel()
    }

    func connect(baseURL: URL) {
        disconnect()
        ensureStalledCheck()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = .infinity
        configuration.timeoutIntervalForResource = .infinity
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        let request = URLRequest(url: baseURL.appendingPathComponent("event"))
        task = session?.dataTask(with: request)
        task?.resume()
        connectedAt = Date()
        Log.stream.info("SSE connecting to \(baseURL.absoluteString, privacy: .public)")
    }

    func disconnect() {
        // Nil out the task first so the completion callback knows the close
        // was intentional and does not trigger a reconnect.
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        buffer = Data()
        scanOffset = 0
        lastReceiveDate = nil
        connectedAt = nil
        isReceivingHeartbeats = false
        lastHTTPStatus = nil
        consecutiveDecodeFailures = 0
        stalledCheck?.cancel()
        stalledCheck = nil
    }

    /// Explicit helpers for the two response dispositions. Keeping the raw
    /// URLSession callback thin avoids repeating session teardown and gives
    /// tests direct coverage of the fatal-path state transitions.
    func acceptResponse(statusCode: Int, contentType: String) {
        lastHTTPStatus = statusCode
    }

    func rejectResponse(statusCode: Int?, contentType: String) {
        lastHTTPStatus = statusCode
        // Mirror a cancelled task: no socket is live after a fatal response,
        // so a later didCompleteWithError must not trigger a reconnect.
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onFatalResponse?(statusCode, contentType)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lastReceiveDate = Date()
        isReceivingHeartbeats = true
        ingest(data)
    }

    /// Reject non-SSE responses up front. Previously a 401/404 (or an HTML
    /// error page) was consumed as an empty stream and reconnected forever,
    /// leaving the UI stuck on "reconnecting" with no diagnosis.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        // Missing Content-Type is tolerated for older builds; an explicit
        // non-event-stream type (usually text/html) is a hard failure.
        if Self.isRejectableResponse(statusCode: http.statusCode, contentType: contentType) {
            Log.stream.warning(
                "SSE rejected: HTTP \(http.statusCode, privacy: .public) \(contentType, privacy: .public)"
            )
            completionHandler(.cancel)
            rejectResponse(statusCode: http.statusCode, contentType: contentType)
            return
        }
        acceptResponse(statusCode: http.statusCode, contentType: contentType)
        completionHandler(.allow)
    }

    /// Pure predicate so the rejection policy is testable without a socket.
    static func isRejectableResponse(statusCode: Int, contentType: String) -> Bool {
        let type = contentType.lowercased()
        let isEventStream = type.isEmpty || type.contains("text/event-stream")
        return statusCode != 200 || !isEventStream
    }

    /// A socket with no bytes for longer than `timeout` is likely dead. DevEco
    /// normally sends periodic SSE comments, so 15s is a conservative guard.
    /// The timer fires every 5s, so the timeout must be >= 2 timer intervals
    /// to avoid false positives on a slightly slow but healthy connection.
    func heartbeatIsStale(timeout: TimeInterval = 15) -> Bool {
        guard let reference = lastReceiveDate ?? connectedAt else { return false }
        let elapsed = Date().timeIntervalSince(reference)
        return elapsed >= max(0, timeout)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.task === task else { return }
        self.task = nil
        Log.stream.info("SSE closed (error: \(error?.localizedDescription ?? "clean close", privacy: .public))")
        // A rejected HTTP response nils `task` before cancelling, so it never
        // reaches this point and cannot drag the caller into a reconnect loop.
        // Reconnect on any close we did not initiate, including a clean close
        // (error == nil) after the server restarts.
        onDisconnect?()
    }

    /// Appends raw bytes and drains every complete SSE frame from the buffer.
    /// Exposed for tests.
    func ingest(_ data: Data) {
        lastReceiveDate = Date()
        isReceivingHeartbeats = true
        buffer.append(data)
        while let frame = nextFrameData() {
            handleFrame(frame)
        }
    }

    private func nextFrameData() -> Data? {
        // 逐字节扫描空行（LF LF 或 CR LF CR LF），避免 UTF-8 多字节字符
        // 跨网络分片时被切断——我们只在完整帧边界处转为 String。
        // Scan raw bytes in place: `[UInt8](buffer)` copied the whole buffer
        // for every chunk, which becomes expensive for long tool output.
        var found: (frameEnd: Int, consumeEnd: Int)?
        buffer.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = rawBuffer.count
            var i = scanOffset
            while i < count, found == nil {
                if bytes[i] == 0x0A { // LF
                    let hasCR = i > 0 && bytes[i - 1] == 0x0D
                    let terminatorStart = hasCR ? i - 1 : i
                    if i + 1 < count, bytes[i + 1] == 0x0A {
                        // "\n\n" 或 "\r\n\n"
                        found = (terminatorStart, i + 2)
                    } else if hasCR, i + 2 < count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                        // "\r\n\r\n"
                        found = (i - 1, i + 3)
                    }
                } else if bytes[i] == 0x0D, // 兼容 "\n\r\n"
                          i > 0, bytes[i - 1] == 0x0A,
                          i + 1 < count, bytes[i + 1] == 0x0A {
                    found = (i - 1, i + 2)
                }
                i += 1
            }
            // No complete frame: retain one byte of overlap so a CR/LF pair
            // split across two network chunks can still be recognised.
            if found == nil { scanOffset = max(0, count - 1) }
        }
        guard let found else { return nil }
        let frame = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + found.frameEnd))
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + found.consumeEnd))
        scanOffset = 0
        return frame
    }

    private func handleFrame(_ data: Data) {
        guard let frame = String(data: data, encoding: .utf8) else { return }
        var payloads: [String] = []
        for rawLine in frame.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("data:") {
                payloads.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        guard !payloads.isEmpty else { return }
        // SSE allows one event to span several `data:` lines; join them.
        let payload = payloads.joined(separator: "\n")
        guard let json = payload.data(using: .utf8),
              let event = try? JSONDecoder.deveco.decode(DevEvent.self, from: json) else {
            consecutiveDecodeFailures += 1
            let summary = ServerManager.redact(String(payload.prefix(120)))
            if consecutiveDecodeFailures == Self.failureWarningThreshold {
                Log.stream.warning("Dropped \(self.consecutiveDecodeFailures) consecutive SSE frames; server event schema may have changed. Payload prefix: \(summary, privacy: .public)")
            } else {
                Log.stream.debug("dropped undecodable SSE frame (\(summary, privacy: .public))")
            }
            return
        }
        consecutiveDecodeFailures = 0
        onEvent?(event)
    }
}
