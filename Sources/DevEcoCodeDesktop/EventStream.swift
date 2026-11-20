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
        var range = buffer.range(of: Data("\n\n".utf8))
        if range == nil { range = buffer.range(of: Data("\r\n\r\n".utf8)) }
        guard let terminator = range else { return nil }
        let frame = buffer.subdata(in: buffer.startIndex..<terminator.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<terminator.upperBound)
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
            Log.stream.debug("dropped undecodable SSE frame (\(payload.prefix(120), privacy: .public))")
            return
        }
        onEvent?(event)
    }
}
