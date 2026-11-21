import XCTest
@testable import DevEcoCodeDesktop

@MainActor
final class PolishFixTests: XCTestCase {
    private var savedClientAutoTitles: [String: String] = [:]
    private var savedManualTitles: [String] = []
    private var savedSessions: Data?

    override func setUp() {
        super.setUp()
        savedClientAutoTitles = AppSettings.clientAutoTitles
        savedManualTitles = AppSettings.manuallyRenamedSessionIDs
        savedSessions = UserDefaults.standard.data(forKey: "cachedSessions")
        AppSettings.clientAutoTitles = [:]
        AppSettings.manuallyRenamedSessionIDs = []
        UserDefaults.standard.removeObject(forKey: "cachedSessions")
    }

    override func tearDown() {
        AppSettings.clientAutoTitles = savedClientAutoTitles
        AppSettings.manuallyRenamedSessionIDs = savedManualTitles
        if let savedSessions {
            UserDefaults.standard.set(savedSessions, forKey: "cachedSessions")
        } else {
            UserDefaults.standard.removeObject(forKey: "cachedSessions")
        }
        super.tearDown()
    }

    private func makeSession(id: String, title: String) -> Session {
        Session(id: id, title: title, directory: nil, time: nil, revert: nil)
    }

    private func sessionEvent(id: String, title: String) throws -> DevEvent {
        let json = """
        {"type":"session.updated","properties":{"info":{"id":"\(id)","title":"\(title)"}}}
        """
        return try JSONDecoder.deveco.decode(DevEvent.self, from: Data(json.utf8))
    }

    func testClientPromptTitleSurvivesServerSnapshot() throws {
        let store = SessionStore()
        store.sessions = [makeSession(id: "ses_title_1", title: "检查核心逻辑")]
        store.connect(baseURL: URL(string: "http://127.0.0.1:4099")!)
        store.setClientTitle("检查核心逻辑", for: "ses_title_1")

        store.handle(try sessionEvent(id: "ses_title_1", title: "ChatView SessionStore"))

        XCTAssertEqual(store.session(for: "ses_title_1")?.title, "检查核心逻辑")
    }

    func testClientPromptTitleSurvivesSSEPlaceholder() throws {
        let store = SessionStore()
        store.sessions = [makeSession(id: "ses_title_2", title: "排查自动标题")]
        store.setClientTitle("排查自动标题", for: "ses_title_2")

        store.handle(try sessionEvent(id: "ses_title_2", title: "New session"))

        XCTAssertEqual(store.session(for: "ses_title_2")?.title, "排查自动标题")
    }

    func testManualRenameAllowsServerTitle() throws {
        let store = SessionStore()
        store.sessions = [makeSession(id: "ses_title_3", title: "旧标题")]
        store.setClientTitle("旧标题", for: "ses_title_3")
        store.markManuallyRenamed("ses_title_3")

        store.handle(try sessionEvent(id: "ses_title_3", title: "ChatView SessionStore"))

        XCTAssertEqual(store.session(for: "ses_title_3")?.title, "ChatView SessionStore")
    }

    func testSessionTitleCanBeUpdatedOptimistically() {
        var session = Session(
            id: "ses_1",
            title: "New session",
            directory: nil,
            time: nil,
            revert: nil
        )
        session.title = "检查核心逻辑"
        XCTAssertEqual(session.title, "检查核心逻辑")
    }

    func testTitleSeedDoesNotSplitEmoji() {
        let store = SessionStore()
        let seed = store.titleSeed(from: String(repeating: "😀", count: 60))
        XCTAssertNotNil(seed)
        XCTAssertFalse(seed!.contains("\u{FFFD}"))
    }

    func testDraftRevisionTracksExternalAssignments() {
        let store = SessionStore()
        let initial = store.draftToken
        store.draft = "hello"
        XCTAssertEqual(store.draftToken, initial)
        store.bumpDraftToken()
        XCTAssertNotEqual(store.draftToken, initial)
    }

    func testComposerPlaceholderDoesNotBecomeDraft() {
        let store = SessionStore()
        let placeholder = NSLocalizedString("Write a message…", comment: "")
        XCTAssertFalse(placeholder.isEmpty)
        XCTAssertEqual(store.draft, "")
        XCTAssertNotEqual(store.draft, placeholder)
    }

    func testSubmitClearsDraftAndBumpsToken() {
        let store = SessionStore()
        store.connect(baseURL: URL(string: "http://127.0.0.1:4099")!)
        store.selectedSessionID = "ses_verify_send"
        store.draft = "验证发送后清空"
        let previousToken = store.draftToken
        store.send()
        XCTAssertEqual(store.draft, "")
        XCTAssertNotEqual(store.draftToken, previousToken)
    }

    func testQuestionToolInputIsDecodedFromStructuredQuestions() throws {
        let input = JSONValue.object([
            "questions": .array([
                .object([
                    "header": .string("清理范围"),
                    "question": .string("清理范围选哪个？"),
                    "options": .array([
                        .object(["label": .string("仅测试文件"), "description": .string("安全")]),
                        .object(["label": .string("全部"), "description": .null]),
                    ]),
                ])
            ])
        ])
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let object) = decoded,
              case .array(let rawQuestions) = object["questions"],
              let first = rawQuestions.first,
              let data = try? JSONEncoder().encode(first),
              let question = try? JSONDecoder().decode(UserQuestionInfo.self, from: data) else {
            return XCTFail("question tool input should decode into structured data")
        }
        XCTAssertEqual(question.header, "清理范围")
        XCTAssertEqual(question.question, "清理范围选哪个？")
        XCTAssertEqual(question.options.map(\.label), ["仅测试文件", "全部"])
    }

    func testToolTraceParsesRawTaskTranscript() {
        let raw = """
        description: 审查 SessionStore 状态机 bug
        prompt: 你是资深审查专家。
        subagent_type general
        <task id="ses_1" state="completed">
        <task_result>
        发现三个真实问题。
        </task_result>
        """
        let trace = ToolTrace.parse(raw)
        XCTAssertEqual(trace.description, "审查 SessionStore 状态机 bug")
        XCTAssertTrue(trace.prompt.contains("你是资深审查专家"))
        XCTAssertTrue(trace.result.contains("发现三个真实问题"))
        XCTAssertFalse(trace.result.contains("<task"))
        XCTAssertTrue(ToolTrace.looksLikeRawTrace(raw))
    }

    func testToolTraceStripsTrailingSubagentType() {
        let raw = """
        description: 审查网络层
        prompt: 只审查真实 bug。
        subagent_type general
        <task_result>完成</task_result>
        """
        let trace = ToolTrace.parse(raw)
        XCTAssertEqual(trace.subagentType, "general")
        XCTAssertFalse(trace.prompt.contains("subagent_type"))
        XCTAssertEqual(trace.result, "完成")
    }

    func testToolTraceExtractsTrailingDescriptionFromPrompt() {
        let raw = """
        prompt: 请只审查真实 bug。
        输出格式：列出问题。, subagent_type: general, description: 审查服务与网络层
        """
        let trace = ToolTrace.parse(raw)
        XCTAssertEqual(trace.description, "审查服务与网络层")
        XCTAssertEqual(trace.subagentType, "general")
        XCTAssertTrue(trace.prompt.contains("请只审查真实 bug"))
        XCTAssertFalse(trace.prompt.contains("description: 审查服务与网络层"))
        XCTAssertFalse(trace.prompt.contains("subagent_type: general"))
    }
}
