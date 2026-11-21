import XCTest
@testable import DevEcoCodeDesktop

final class ReliabilityFixTests: XCTestCase {
    func testLogRedactionMasksSecrets() {
        let raw = "Authorization: Bearer sk-abcdefgh12345678 and key=sk-abcdefgh12345678"
        let redacted = ServerManager.redact(raw)
        XCTAssertFalse(redacted.contains("sk-abcdefgh12345678"))
        XCTAssertFalse(redacted.contains("abcdefgh12345678"))
        XCTAssertTrue(redacted.contains("REDACTED"))
    }

    func testLogRedactionLeavesNormalText() {
        let text = "deveco serve listening on 127.0.0.1:4096"
        XCTAssertEqual(ServerManager.redact(text), text)
    }

    func testSSEMultipleFramesMixedTerminators() {
        let stream = EventStream()
        var types: [String] = []
        stream.onEvent = { types.append($0.type) }
        let chunk = Data((
            "data: {\"type\":\"a\"}\r\n\r\n" +
            "data: {\"type\":\"b\"}\n\n"
        ).utf8)
        stream.ingest(chunk)
        XCTAssertEqual(types, ["a", "b"])
    }

    func testSSESplitFrameStillWorks() {
        let stream = EventStream()
        var types: [String] = []
        stream.onEvent = { types.append($0.type) }
        let frame = Data("data: {\"type\":\"你好\"}\n\n".utf8)
        let cut = frame.count - 3
        stream.ingest(frame.subdata(in: 0..<cut))
        stream.ingest(frame.subdata(in: cut..<frame.count))
        XCTAssertEqual(types, ["你好"])
    }

    func testProcessGroupLauncherForwardsChildOutput() throws {
        let pipe = Pipe()
        let config = ProcessGroupLauncher.Configuration(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'hello-from-child\\n'"],
            environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory,
            stdout: pipe.fileHandleForWriting,
            stderr: pipe.fileHandleForWriting
        )
        let launched = try ProcessGroupLauncher.launch(config)
        defer { launched.terminate(gracePeriod: 0) }
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello-from-child\n")
    }
}
