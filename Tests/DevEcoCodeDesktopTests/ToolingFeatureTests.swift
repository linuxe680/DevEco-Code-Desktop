import XCTest
@testable import DevEcoCodeDesktop

final class ToolingFeatureTests: XCTestCase {
    func testLocationQueryUsesDeepObjectKeys() {
        let query = APIClient.locationQuery(directory: "/tmp/project", workspace: "wrk_1")
        XCTAssertEqual(query["location[directory]"], "/tmp/project")
        XCTAssertEqual(query["location[workspace]"], "wrk_1")
        XCTAssertTrue(APIClient.locationQuery(directory: nil, workspace: nil).isEmpty)
    }

    func testToolingModelsDecode() throws {
        let skills = try JSONDecoder.deveco.decode(
            SkillListResponse.self,
            from: Data(#"{"location":{},"data":[{"name":"review","location":"project","content":"Do review","description":"Review changes","slash":true}]}"#.utf8)
        )
        XCTAssertEqual(skills.data.first?.name, "review")
        XCTAssertEqual(skills.data.first?.id, "project/review")

        let agents = try JSONDecoder.deveco.decode(
            AgentListResponse.self,
            from: Data(#"{"location":{},"data":[{"id":"build","mode":"subagent","hidden":false,"request":{"headers":{},"body":{}},"permissions":{}}]}"#.utf8)
        )
        XCTAssertEqual(agents.data.first?.id, "build")

        let statuses = try JSONDecoder.deveco.decode(
            [String: MCPStatus].self,
            from: Data(#"{"a":{"status":"connected"},"b":{"status":"failed","error":"boom"},"c":{"status":"needs_auth"}}"#.utf8)
        )
        XCTAssertEqual(statuses["a"], .connected)
        XCTAssertEqual(statuses["b"], .failed("boom"))
        XCTAssertEqual(statuses["c"], .needsAuth)
        XCTAssertTrue(statuses["a"]?.canDisconnect == true)
        XCTAssertTrue(statuses["b"]?.canConnect == true)

        let files = try JSONDecoder.deveco.decode(
            FileListResponse.self,
            from: Data(#"{"location":{},"data":[{"path":"README.md","type":"file","mime":"text/plain"}]}"#.utf8)
        )
        XCTAssertEqual(files.data.first?.path, "README.md")

        let vcs = try JSONDecoder.deveco.decode(
            [VcsStatus].self,
            from: Data(#"[{"file":"a.swift","additions":2,"deletions":1,"status":"modified"}]"#.utf8)
        )
        XCTAssertEqual(vcs.first?.status, "modified")
    }

    func testSessionDecodesShareURL() throws {
        let session = try JSONDecoder.deveco.decode(
            Session.self,
            from: Data(#"{"id":"ses_1","slug":"s","projectID":"prj","directory":"/tmp","title":"T","version":"1","time":{"created":0,"updated":0},"share":{"url":"https://example.com/s"}}"#.utf8)
        )
        XCTAssertEqual(session.share?.url, "https://example.com/s")
    }

    @MainActor
    func testToolQueriesUseSelectedSessionDirectory() throws {
        let store = SessionStore()
        store.fallbackDirectory = "/tmp/fallback-project"
        store.sessions = []
        store.selectedSessionID = nil
        store.sessions = [try JSONDecoder.deveco.decode(
            Session.self,
            from: Data(#"{"id":"ses_tools","directory":"/tmp/tool-project","title":"Tools","time":{"created":0,"updated":0}}"#.utf8)
        )]
        store.selectedSessionID = "ses_tools"

        XCTAssertEqual(store.currentDirectory, "/tmp/tool-project")
        XCTAssertEqual(store.vcsQuery()["location[directory]"], "/tmp/tool-project")
        XCTAssertNil(store.vcsQuery()["mode"])
        XCTAssertEqual(store.vcsQuery(mode: "git")["mode"], "git")
    }

    @MainActor
    func testToolQueriesFallBackToProjectDirectory() throws {
        let store = SessionStore()
        store.fallbackDirectory = "/tmp/fallback-project"
        store.sessions = []
        store.selectedSessionID = nil
        XCTAssertEqual(store.currentDirectory, "/tmp/fallback-project")
        XCTAssertEqual(store.vcsQuery()["location[directory]"], "/tmp/fallback-project")
    }

    func testUserFacingServerErrorIsLocalized() {
        let error = APIError.status(500, #"{"_tag":"InternalServerError"}"#)
        XCTAssertEqual(
            UserFacingError.message(error),
            String(format: NSLocalizedString("Server error (%lld): %@", comment: ""), Int64(500), #"{"_tag":"InternalServerError"}"#)
        )
    }
}
