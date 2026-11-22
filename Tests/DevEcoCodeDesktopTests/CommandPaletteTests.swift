import XCTest
import SwiftUI
@testable import DevEcoCodeDesktop

@MainActor
final class CommandPaletteTests: XCTestCase {
    func testFilteringCoversSessionsAndProjects() throws {
        let sessions = [
            try session(id: "s1", title: "Alpha refactor", directory: "/tmp/alpha"),
            try session(id: "s2", title: "Beta fix", directory: "/tmp/beta"),
        ]
        XCTAssertEqual(GlobalCommandPaletteView.filteredSessions(sessions, query: "alpha").map(\.id), ["s1"])
        XCTAssertEqual(GlobalCommandPaletteView.filteredSessions(sessions, query: "/tmp/beta").map(\.id), ["s2"])
        XCTAssertEqual(GlobalCommandPaletteView.filteredSessions(sessions, query: "").count, 2)

        let projects = [URL(fileURLWithPath: "/tmp/alpha"), URL(fileURLWithPath: "/tmp/beta")]
        XCTAssertEqual(GlobalCommandPaletteView.filteredProjects(projects, query: "beta").map(\.path), ["/tmp/beta"])
        XCTAssertEqual(GlobalCommandPaletteView.filteredProjects(projects, query: "missing"), [])
    }

    func testPermissionDetailsRedactArgumentsAndClassifyRisk() {
        let request = PermissionRequest(
            id: "p1",
            sessionID: "s1",
            permission: "bash",
            patterns: ["curl -H 'Authorization: Bearer abc123' https://example.com"],
            action: nil
        )
        let details = PermissionPresentation.details(for: request, workspace: "/tmp/project")
        XCTAssertEqual(details.tool, "Bash")
        XCTAssertTrue(details.risk.contains("High risk"))
        XCTAssertEqual(details.workspace, "/tmp/project")
        XCTAssertTrue(details.argumentPreview.contains("REDACTED"))
        XCTAssertFalse(details.argumentPreview.contains("abc123"))
    }

    func testWorkPanelStateIsSessionScoped() {
        let store = SessionStore()
        store.selectedSessionID = "s1"
        store.workPanelOpenBySession["s1"] = true
        store.workPanelTab = .context

        store.selectedSessionID = "s2"
        XCTAssertNil(store.workPanelOpenBySession["s2"])
        XCTAssertEqual(store.workPanelTab, .context)

        store.workPanelOpenBySession["s2"] = true
        store.workPanelTab = .review
        store.selectedSessionID = "s1"
        XCTAssertTrue(store.workPanelOpenBySession["s1"] ?? false)
        XCTAssertEqual(store.workPanelTab, .review)
    }

    func testSessionsGroupByProject() throws {
        let groups = SessionProjectGroup.groups([
            try session(id: "s1", title: "Alpha", directory: "/tmp/alpha", updated: 2),
            try session(id: "s2", title: "Beta", directory: "/tmp/beta", updated: 3),
            try session(id: "s3", title: "Alpha 2", directory: "/tmp/alpha", updated: 1),
        ])
        XCTAssertEqual(groups.map(\.path), ["/tmp/beta", "/tmp/alpha"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["s1", "s3"])
    }

    func testDefaultCommandsIncludeCoreWorkbenchActions() {
        XCTAssertFalse(CommandAction.defaults.isEmpty)
        XCTAssertTrue(CommandAction.defaults.contains { $0.title == NSLocalizedString("New Session", comment: "") })
        XCTAssertTrue(CommandAction.defaults.contains { $0.title == NSLocalizedString("Choose Project Folder…", comment: "") })
    }

    private func session(id: String, title: String, directory: String, updated: Int = 2) throws -> Session {
        let json = """
        {"id":"\(id)","title":"\(title)","directory":"\(directory)","time":{"created":1,"updated":\(updated)}}
        """
        return try JSONDecoder.deveco.decode(Session.self, from: Data(json.utf8))
    }
}
