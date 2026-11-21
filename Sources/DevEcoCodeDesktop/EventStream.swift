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

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var lastReceiveDate: Date?
    private let stalledCheck: DispatchSourceTimer

    /// 连续解码失败计数。服务端事件格式变更或密钥轮换时，
    /// 静默丢帧会让 UI 永远停在旧状态——需要显式告警。
    private var consecutiveDecodeFailures = 0
    private static let failureWarningThreshold = 5

    /// True once any SSE byte (including `: keepalive` comments) has arrived.
    /// The UI uses this to distinguish "connected but thinking" from a dead
    /// socket instead of appearing frozen with no explanation.
    private(set) var isReceivingHeartbeats = false

    fileprivate static func makeStalledCheckTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.resume()
        return timer
    }

    override init() {
        stalledCheck = Self.makeStalledCheckTimer()
        super.init()
        stalledCheck.setEventHandler { [weak self] in
            guard let self,
                  self.task != nil,
                  self.heartbeatIsStale() else { return }
            Log.stream.warning("SSE heartbeat stalled — forcing reconnect")
            self.onStalled?()
        }
    }

    deinit {
        stalledCheck.cancel()
    }

    func connect(baseURL: URL) {
        disconnect()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = .infinity
        configuration.timeoutIntervalForResource = .infinity
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        let request = URLRequest(url: baseURL.appendingPathComponent("event"))
        task = session?.dataTask(with: request)
        task?.resume()
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
        lastReceiveDate = nil
        isReceivingHeartbeats = false
        consecutiveDecodeFailures = 0
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lastReceiveDate = Date()
        isReceivingHeartbeats = true
        ingest(data)
    }

    /// A socket with no bytes for longer than `timeout` is likely dead. DevEco
    /// normally sends periodic SSE comments, so 15s is a conservative guard.
    func heartbeatIsStale(timeout: TimeInterval = 15) -> Bool {
        guard let lastReceiveDate else { return false }
        return Date().timeIntervalSince(lastReceiveDate) >= max(0, timeout)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.task === task else { return }
        self.task = nil
        Log.stream.info("SSE closed (error: \(error?.localizedDescription ?? "clean close", privacy: .public))")
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
        buffer.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = rawBuffer.count
            var i = 0
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
                }
                i += 1
            }
        }
        guard let found else { return nil }
        let frame = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + found.frameEnd))
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + found.consumeEnd))
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
            if consecutiveDecodeFailures == Self.failureWarningThreshold {
                Log.stream.warning("Dropped \(self.consecutiveDecodeFailures) consecutive SSE frames; server event schema may have changed. Last payload: \(payload.prefix(120), privacy: .public)")
            } else {
                Log.stream.debug("dropped undecodable SSE frame (\(payload.prefix(120), privacy: .public))")
            }
            return
        }
        consecutiveDecodeFailures = 0
        onEvent?(event)
    }
}
