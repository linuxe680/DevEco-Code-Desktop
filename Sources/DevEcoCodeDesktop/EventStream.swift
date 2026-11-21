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

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()

    /// 连续解码失败计数。服务端事件格式变更或密钥轮换时，
    /// 静默丢帧会让 UI 永远停在旧状态——需要显式告警。
    private var consecutiveDecodeFailures = 0
    private static let failureWarningThreshold = 5

    func connect(baseURL: URL) {
        disconnect()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = .infinity
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
        consecutiveDecodeFailures = 0
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        ingest(data)
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
        buffer.append(data)
        while let frame = nextFrameData() {
            handleFrame(frame)
        }
    }

    private func nextFrameData() -> Data? {
        // 逐字节扫描空行（LF LF 或 CR LF CR LF），避免 UTF-8 多字节字符
        // 跨网络分片时被切断——我们只在完整帧边界处转为 String。
        let bytes = [UInt8](buffer)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A { // LF
                let hasCR = i > 0 && bytes[i - 1] == 0x0D
                let terminatorStart = hasCR ? i - 1 : i
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    // "\n\n" 或 "\r\n\n"：消费两个换行字节
                    let frameEnd = terminatorStart
                    let frame = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + frameEnd))
                    buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + i + 2))
                    return frame
                }
                if hasCR, i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                    // "\r\n\r\n"：消费 CR LF CR LF 共四个字节
                    let frameEnd = i - 1
                    let frame = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + frameEnd))
                    buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + i + 3))
                    return frame
                }
            }
            i += 1
        }
        return nil
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
