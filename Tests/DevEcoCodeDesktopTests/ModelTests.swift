import XCTest
import SwiftUI
@testable import DevEcoCodeDesktop

final class ModelTests: XCTestCase {
    func testJSONValueDecoding() throws {
        let json = #"{"name":"x","count":3,"on":true,"tags":["a"],"nested":{"k":null}}"#
        let value = try JSONDecoder.deveco.decode(JSONValue.self, from: Data(json.utf8))
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["name"]?.stringValue, "x")
        XCTAssertEqual(object["count"]?.intValue, 3)
        XCTAssertEqual(object["on"]?.boolValue, true)
        XCTAssertEqual(object["tags"]?.arrayValue?.count, 1)
        XCTAssertEqual(object["nested"]?.objectValue?["k"], .null)
    }

    // MARK: Access mode

    func testAccessModeDefaultsToAskWithoutRules() {
        XCTAssertEqual(SessionAccessMode.current(for: nil), .ask)
        XCTAssertEqual(SessionAccessMode.current(for: []), .ask)
    }

    func testCachedSessionKeepsPermissionAndModel() throws {
        let json = """
        {"id":"s1","title":"t","directory":null,"time":null,"revert":null,
         "parentID":null,"permission":[{"permission":"bash","pattern":"*","action":"allow"}],
         "model":{"id":"openrouter/openrouter/free","providerID":"magpie","variant":"default"},
         "tokens":null,"cost":null}
        """
        let session = try JSONDecoder.deveco.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(SessionAccessMode.current(for: session.permission), .allowAll)
        XCTAssertEqual(session.model?.modelID, "magpie/openrouter/openrouter/free")
    }

    func testAccessModeFollowsLastMatchingRule() {
        let rules = [
            PermissionRule(permission: "edit", pattern: "*", action: "allow"),
            PermissionRule(permission: "edit", pattern: "*", action: "ask"),
        ]
        // The server appends rules and the last match wins, so a later "ask"
        // must re-arm approvals even when an older "allow" exists.
        XCTAssertEqual(SessionAccessMode.current(for: rules), .ask)
        XCTAssertEqual(SessionAccessMode.current(for: rules.reversed()), .allowAll)
    }

    func testAccessModeIgnoresReadOnlyRules() {
        let rules = [
            PermissionRule(permission: "read", pattern: "*", action: "allow"),
            PermissionRule(permission: "grep", pattern: "*", action: "allow"),
        ]
        XCTAssertEqual(SessionAccessMode.current(for: rules), .ask)
    }

    func testAccessModeRulesCoverEveryGatedTool() {
        for mode in SessionAccessMode.allCases {
            XCTAssertEqual(
                Set(mode.rules.map(\.permission)),
                Set(SessionAccessMode.gatedPermissions)
            )
            XCTAssertTrue(mode.rules.allSatisfy { $0.pattern == "*" })
        }
        XCTAssertTrue(SessionAccessMode.allowAll.rules.allSatisfy { $0.action == "allow" })
        XCTAssertTrue(SessionAccessMode.ask.rules.allSatisfy { $0.action == "ask" })
    }

    func testPartWithoutIDGetsStableIdentity() throws {
        let json = #"{"type":"step-start"}"#
        let part = try JSONDecoder.deveco.decode(Part.self, from: Data(json.utf8))
        XCTAssertFalse(part.id.isEmpty)
        XCTAssertEqual(part.type, "step-start")
    }

    func testSessionUpdatedAtFromMillis() throws {
        let json = #"{"id":"s1","title":"t","directory":"/tmp/p","time":{"created":1700000000000,"updated":1700000001000}}"#
        let session = try JSONDecoder.deveco.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.updatedAt?.timeIntervalSince1970, 1_700_000_001)
        XCTAssertFalse(session.isArchived)
    }

    func testMessageTokensContextUsedFallsBackToInputAndCache() throws {
        let json = #"{"input":1200,"output":42,"cache":{"read":3400}}"#
        let tokens = try JSONDecoder.deveco.decode(MessageTokens.self, from: Data(json.utf8))
        XCTAssertEqual(tokens.contextUsed, 4600)
    }

    func testMessageTokensContextExcludesThisTurnOutput() throws {
        // `total` is a spend counter (input + output + reasoning). The context
        // gauge must only count what the model had to read, otherwise a short
        // reply looks like it nearly filled the window.
        let json = #"{"total":19330,"input":19099,"output":70,"reasoning":161}"#
        let tokens = try JSONDecoder.deveco.decode(MessageTokens.self, from: Data(json.utf8))
        XCTAssertEqual(tokens.contextUsed, 19099)
    }

    func testMessageTokensContextFallsBackToTotalMinusGenerated() throws {
        let json = #"{"total":5000,"output":120,"reasoning":80}"#
        let tokens = try JSONDecoder.deveco.decode(MessageTokens.self, from: Data(json.utf8))
        XCTAssertEqual(tokens.contextUsed, 4800)
    }

    func testSessionArchivedFlag() throws {
        let json = #"{"id":"s1","title":"t","directory":"/tmp/p","time":{"created":1700000000000,"updated":1700000001000,"archived":1730000000000}}"#
        let session = try JSONDecoder.deveco.decode(Session.self, from: Data(json.utf8))
        XCTAssertTrue(session.isArchived)

        let jsonZero = #"{"id":"s1","title":"t","time":{"created":1,"updated":2,"archived":0}}"#
        XCTAssertFalse(try JSONDecoder.deveco.decode(Session.self, from: Data(jsonZero.utf8)).isArchived)
    }

    func testMarkdownSegmentParsing() {
        let content = """
        Intro **bold** text.
        ```swift
        let x = 1
        ```
        Outro text.
        """
        XCTAssertEqual(
            parseMarkdownSegments(content),
            [
                .text("Intro **bold** text."),
                .code(lang: "swift", code: "let x = 1"),
                .text("Outro text."),
            ]
        )
    }

    func testMarkdownUnterminatedFenceRendersAsCode() {
        let segments = parseMarkdownSegments("text\n```bash\necho hi")
        XCTAssertEqual(
            segments,
            [.text("text"), .code(lang: "bash", code: "echo hi")]
        )
    }

    func testMarkdownPlainTextStaysSingleSegment() {
        let segments = parseMarkdownSegments("just text\nwith lines")
        XCTAssertEqual(segments, [.text("just text\nwith lines")])
    }

    func testAssistantMessageUsageDecodes() throws {
        let json = """
        {"id":"msg_1","role":"assistant","modelID":"m","providerID":"p",
         "cost":0.0412,"tokens":{"input":1234,"output":3456,"reasoning":100,"cache":{"read":99,"write":7}},
         "time":{"created":1700000000000,"completed":1700000002500}}
        """
        let info = try JSONDecoder.deveco.decode(MessageInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.cost, 0.0412)
        XCTAssertEqual(info.tokens?.input, 1234)
        XCTAssertEqual(info.tokens?.cache?.read, 99)
        XCTAssertEqual(info.elapsedMilliseconds, 2500)
        XCTAssertEqual(info.elapsedDuration, "2.50s")
    }

    func testPartDecodesStringToolState() throws {
        let json = """
        {"id":"p1","type":"tool","tool":"bash","state":"completed"}
        """
        let part = try JSONDecoder.deveco.decode(Part.self, from: Data(json.utf8))
        XCTAssertEqual(part.state?.status, "completed")
        XCTAssertEqual(part.state?.summary, "Completed")
    }

    func testDurationFormatting() {
        XCTAssertEqual(formatChatDuration(milliseconds: 0), "<0.01s")
        XCTAssertEqual(formatChatDuration(milliseconds: 850), "0.85s")
        XCTAssertEqual(formatChatDuration(milliseconds: 12_400), "12.4s")
        XCTAssertEqual(formatChatDuration(milliseconds: 65_000), "1m 05s")
        XCTAssertEqual(prettyModelName("Hy4 flash (hy4flash) · WorkBuddy"), "Hy4 flash · WorkBuddy")
        XCTAssertEqual(prettyModelName("DeepSeek-V4.1-Flash · Trae CN"), "DeepSeek-V4.1-Flash · Trae CN")
    }

    func testMarkdownProseBlocks() {
        let content = """
        # Summary
        A paragraph with **bold** text.

        - first item
        - second item

        > quoted note

        1. ordered item
        ---
        """
        XCTAssertEqual(
            parseMarkdownProseBlocks(content),
            [
                .heading(level: 1, text: "Summary"),
                .paragraph("A paragraph with **bold** text."),
                .bullet("first item"),
                .bullet("second item"),
                .quote("quoted note"),
                .numbered(number: 1, text: "ordered item"),
                .divider,
            ]
        )
    }

    func testMarkdownProseBlocksHideRecallNotice() {
        let content = """
        💡 Recalled 2 memories: deveco-code-desktop-project(project), chinese-language-preference(user)
        耐心是一种安静的力量。
        """
        XCTAssertEqual(
            parseMarkdownProseBlocks(content),
            [
                .paragraph("耐心是一种安静的力量。"),
            ]
        )
    }

    func testSystemNoticeTextDropsDecorativePrefix() {
        let notice = "💡 Recalled 2 memories: deveco-code-desktop-project(project)"
        XCTAssertEqual(
            systemNoticeText(notice),
            "Recalled 2 memories: deveco-code-desktop-project(project)"
        )
    }

    func testRemovingSystemNoticeLinesKeepsAnswerBody() {
        let text = """
        💡 Recalled 2 memories: deveco-code-desktop-project(project)

        你好！有什么可以帮你的吗？
        """
        XCTAssertEqual(removingSystemNoticeLines(text), "你好！有什么可以帮你的吗？")
    }

    func testUserPromptIsNeverTreatedAsSystemNotice() {
        let prompt = "searching for the crash (in Sources)"
        XCTAssertEqual(visiblePartText(prompt, useMarkdown: false), prompt)
        XCTAssertEqual(removingSystemNoticeLines(prompt), "")
    }

    func testTokenMetadataDistinguishesGeneratedFromContext() {
        let generatedKey = NSLocalizedString("Generated %@ tokens", comment: "")
        let contextKey = NSLocalizedString("Context window", comment: "")
        XCTAssertFalse(generatedKey.contains("输出"))
        XCTAssertFalse(contextKey.contains("输入"))
        XCTAssertFalse(contextKey.isEmpty)
        XCTAssertTrue(generatedKey.contains("token"))
    }

    func testCompactCountDropsTrailingZeroDecimal() {
        XCTAssertEqual(compactTokenCount(960_000), "960k")
        XCTAssertEqual(compactTokenCount(20_300), "20.3k")
        XCTAssertEqual(compactTokenCount(1_500_000), "1.5M")
        XCTAssertEqual(compactTokenCount(999), "999")
    }

    func testChatTypographyClampsAndScales() {
        XCTAssertEqual(ChatTypography.body(8), 13)
        XCTAssertEqual(ChatTypography.body(34), 30)
        XCTAssertTrue(ChatTypography.code(18) < ChatTypography.body(18))
        XCTAssertTrue(ChatTypography.heading(14, level: 1) > ChatTypography.heading(14, level: 3))
    }

    func testPrettyModelNameUsesChineseLabelForKnownModels() {
        XCTAssertEqual(prettyModelName("Hy4 flash (hy4flash)"), "混元 Flash")
    }

    func testServerModelIDWithVendorSuffixResolvesToCatalogName() {
        let catalog = [
            (key: normalizedModelKey("magpie/workbuddy/hy4flash-free"), name: "Hy4 flash · WorkBuddy"),
            (key: normalizedModelKey("magpie/trae-cn/deepseek-v4.1-flash"), name: "DeepSeek-V4.1-Flash · Trae CN"),
            (key: normalizedModelKey("magpie/trae-cn/deepseek-v4.1-flash-max"), name: "DeepSeek-V4.1-Flash (Max) · Trae CN"),
        ]
        XCTAssertEqual(
            uniqueCatalogModelName(for: "magpie/workbuddy/hy4flash", in: catalog),
            "Hy4 flash · WorkBuddy"
        )
        XCTAssertEqual(
            uniqueCatalogModelName(for: "magpie/trae-cn/deepseek-v4.1-flash", in: catalog),
            "DeepSeek-V4.1-Flash · Trae CN"
        )
        XCTAssertNil(uniqueCatalogModelName(for: "magpie/trae-cn/deepseek-v4.1", in: catalog))
        XCTAssertNil(uniqueCatalogModelName(for: "magpie/unknown/model", in: catalog))
    }

    func testPlaceholderSessionTitleDisplaysInChinese() throws {
        let json = #"{"id":"s1","title":"New session"}"#
        let session = try JSONDecoder.deveco.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.displayTitle, NSLocalizedString("New session", comment: ""))
    }

    func testTodoItemDecode() throws {
        let json = #"[{"content":"Write tests","status":"in_progress","priority":"high"},{"content":"Ship","status":"pending","priority":"low"}]"#
        let todos = try JSONDecoder.deveco.decode([TodoItem].self, from: Data(json.utf8))
        XCTAssertEqual(todos.count, 2)
        XCTAssertEqual(todos[0].id, "Write tests")
        XCTAssertTrue(todos[0].isInProgress)
        XCTAssertFalse(todos[1].isDone)
    }

    func testFileDiffDecode() throws {
        let json = #"[{"file":"src/a.swift","patch":"@@ -1 +1 @@","additions":12,"deletions":3,"status":"modified"},{"file":"new.md","additions":5,"deletions":0,"status":"added"}]"#
        let diffs = try JSONDecoder.deveco.decode([FileDiff].self, from: Data(json.utf8))
        XCTAssertEqual(diffs.count, 2)
        XCTAssertEqual(diffs[0].id, "src/a.swift")
        XCTAssertEqual(diffs[1].status, "added")
    }

    func testSessionRevertDecode() throws {
        let json = #"{"id":"s1","title":"t","directory":"/p","revert":{"messageID":"msg_1","snapshot":"snap"},"time":{"created":1,"updated":2}}"#
        let session = try JSONDecoder.deveco.decode(Session.self, from: Data(json.utf8))
        XCTAssertTrue(session.isReverted)
        XCTAssertEqual(session.revert?.messageID, "msg_1")
    }

    func testUserQuestionRequestDecode() throws {
        let json = """
        {"id":"que_1","sessionID":"ses_1","questions":[
          {"question":"Which framework?","header":"Choice","multiple":true,"custom":true,
           "options":[{"label":"SwiftUI","description":"Native"},{"label":"AppKit"}]}
        ]}
        """
        let request = try JSONDecoder.deveco.decode(UserQuestionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.id, "que_1")
        XCTAssertEqual(request.questions.count, 1)
        XCTAssertEqual(request.questions[0].options.count, 2)
        XCTAssertEqual(request.questions[0].options[0].description, "Native")
        XCTAssertEqual(request.questions[0].multiple, true)
        XCTAssertEqual(request.questions[0].custom, true)
    }

    func testQuestionDraftDefaultsAreEmpty() {
        let draft = QuestionDraft()
        XCTAssertTrue(draft.selections.isEmpty)
        XCTAssertTrue(draft.customAnswers.isEmpty)
    }

    func testVcsInfoAndUsageDecode() throws {
        let vcs = try JSONDecoder.deveco.decode(VcsInfo.self, from: Data(#"{"branch":null,"default_branch":"main"}"#.utf8))
        XCTAssertNil(vcs.branch)
        XCTAssertEqual(vcs.defaultBranch, "main")

        let usage = try JSONDecoder.deveco.decode(
            UsageSummary.self,
            from: Data(#"{"total":{"sessions":4,"messages":19,"cost":1.234}}"#.utf8)
        )
        XCTAssertEqual(usage.total?.sessions, 4)
        XCTAssertEqual(usage.total?.cost, 1.234)
    }

    func testFsFindResponseDecode() throws {
        let json = """
        {"location":{"directory":"/p"},"data":[
          {"path":"src/a.swift","type":"file","mime":"text/x-swift"},
          {"path":"docs","type":"directory","mime":null}
        ]}
        """
        let response = try JSONDecoder.deveco.decode(FsFindResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data?.count, 2)
        XCTAssertEqual(response.data?[0].path, "src/a.swift")
    }

    func testModelLimitDecode() throws {
        let json = #"{"id":"m","providerID":"p","limit":{"context":960000,"output":64000}}"#
        let model = try JSONDecoder.deveco.decode(ServerModel.self, from: Data(json.utf8))
        XCTAssertEqual(model.limit?.context, 960000)
        XCTAssertEqual(model.limit?.output, 64000)
    }

    func testHighlighterPreservesTextAndColors() {
        let code = """
        // greet
        let name = "world"
        """
        let attributed = CodeHighlighter.highlight(code, language: "swift")
        XCTAssertEqual(String(attributed.characters), code)
        // Keyword, string, and comment runs must carry distinct colors.
        var colors = Set<Color>()
        for run in attributed.runs {
            colors.insert(run.foregroundColor ?? Color.primary)
        }
        XCTAssertGreaterThanOrEqual(colors.count, 4, "expected comment/string/keyword/default coloring")
    }

    func testModelListResponseDecode() throws {
        let json = """
        {"location":{"directory":"/p"},"data":[
          {"id":"zcode/GLM-5.3-Flash","name":"GLM-5.3-Flash · ZCode","providerID":"magpie"},
          {"id":"glm-5.3-flash-free","name":"GLM-5.3-Flash Free","providerID":"opencode"}
        ]}
        """
        let response = try JSONDecoder.deveco.decode(ModelListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data?.count, 2)
        XCTAssertEqual(response.data?[0].providerID, "magpie")
        XCTAssertEqual(response.data?[1].id, "glm-5.3-flash-free")
    }

    func testDevCommandDecode() throws {
        let json = #"[{"name":"review","description":"Review code","source":"command","template":"review $ARGUMENTS","hints":[]},{"name":"commit","source":"skill","template":"commit","hints":[]}]"#
        let commands = try JSONDecoder.deveco.decode([DevCommand].self, from: Data(json.utf8))
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].name, "review")
        XCTAssertEqual(commands[0].source, "command")
        XCTAssertEqual(commands[1].source, "skill")
    }

    func testSessionParentIDDecode() throws {
        let json = #"{"id":"ses_child","parentID":"ses_parent","title":"sub","time":{"created":1,"updated":2}}"#
        let session = try JSONDecoder.deveco.decode(Session.self, from: Data(json.utf8))
        XCTAssertTrue(session.isSubagent)
        XCTAssertEqual(session.parentID, "ses_parent")
    }

    func testColorizedDiffPreservesTextAndColorsLines() {
        let patch = """
        @@ -1,3 +1,4 @@
        unchanged line
        -removed line
        +added line
        """
        let attributed = colorizedDiff(patch)
        XCTAssertEqual(String(attributed.characters), patch + "\n")

        // Added/removed/context lines must get distinct colors.
        var colors = Set<Color>()
        for run in attributed.runs {
            colors.insert(run.foregroundColor ?? Color.primary)
        }
        XCTAssertGreaterThanOrEqual(colors.count, 3, "expected +/-/context lines to differ in color")
    }

    func testTranscriptExport() {
        let session = Session(id: "s1", title: "Test session", directory: "/tmp/project", time: nil, revert: nil)
        let messages = [
            MessageRecord(
                info: MessageInfo(id: "msg_1", role: "user"),
                parts: [Part(id: "p1", type: "text", text: "Fix the bug")]
            ),
            MessageRecord(
                info: MessageInfo(
                    id: "msg_2", role: "assistant", modelID: "gpt", providerID: "openai", cost: 0.05
                ),
                parts: [
                    Part(id: "p2", type: "reasoning", text: "thinking about it"),
                    Part(id: "p3", type: "tool", tool: "bash", state: ToolState(status: "completed", title: "ls -la", output: nil, error: nil, input: nil)),
                    Part(id: "p4", type: "text", text: "Done."),
                ]
            ),
        ]
        let markdown = TranscriptExporter.markdown(session: session, messages: messages)

        XCTAssertTrue(markdown.contains("# Test session"))
        XCTAssertTrue(markdown.contains("- Project: `project`"))
        XCTAssertTrue(markdown.contains("- Model: `openai/gpt`"))
        XCTAssertTrue(markdown.contains("## You"))
        XCTAssertTrue(markdown.contains("Fix the bug"))
        XCTAssertTrue(markdown.contains("<details><summary>Thinking</summary>"))
        XCTAssertTrue(markdown.contains("🔨 **Bash**"))
        XCTAssertTrue(markdown.contains("Done."))
        XCTAssertTrue(markdown.contains("$0.05"))
    }

    func testDevEventAccessors() throws {
        let json = #"{"type":"session.error","properties":{"sessionID":"s1","error":{"message":"boom"}}}"#
        let event = try JSONDecoder.deveco.decode(DevEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.property("sessionID"), "s1")
        XCTAssertEqual(event.object("error")?["message"]?.stringValue, "boom")
    }

    func testProviderEntryRoundTripPreservesUnknownFields() throws {
        let json = """
        {
          "name": "My Provider",
          "npm": "@ai-sdk/openai-compatible",
          "options": {"baseURL": "https://api.example.com/v1", "apiKey": "sk-123", "customFlag": true},
          "models": {
            "model-a": {"name": "Model A", "limit": {"context": 128000, "output": 8192}, "extra": {"x": 1}}
          }
        }
        """
        let value = try JSONDecoder.deveco.decode(JSONValue.self, from: Data(json.utf8))
        let provider = try XCTUnwrap(ProviderEntry.parse(id: "my-provider", value: value))

        XCTAssertEqual(provider.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(provider.apiKey, "sk-123")
        XCTAssertEqual(provider.models.count, 1)
        XCTAssertEqual(provider.models[0].context, 128000)

        var modified = provider
        modified.models[0].reasoning = true

        let out = modified.jsonValue()
        let modelObject = try XCTUnwrap(out.objectValue?["models"]?.objectValue?["model-a"]?.objectValue)
        XCTAssertEqual(modelObject["reasoning"]?.boolValue, true)
        // Fields the app doesn't model must survive the round trip.
        XCTAssertEqual(modelObject["extra"]?.objectValue?["x"]?.intValue, 1)
        XCTAssertEqual(provider.jsonValue().objectValue?["options"]?.objectValue?["customFlag"]?.boolValue, true)
    }

    // MARK: - Stranded question cards

    private func pendingQuestion(
        id: String = "que_1",
        sessionID: String = "ses_1",
        text: String = "下一步做什么？"
    ) -> UserQuestionRequest {
        UserQuestionRequest(
            id: id,
            sessionID: sessionID,
            questions: [
                UserQuestionInfo(
                    question: text,
                    header: "下一步",
                    options: [UserQuestionOption(label: "继续", description: nil)],
                    multiple: false,
                    details: nil,
                    custom: nil
                )
            ]
        )
    }

    func testQuestionCardExpiresWhenServerLostItsPendingRequest() {
        XCTAssertTrue(QuestionCardState.isExpired(
            tool: "question",
            status: "running",
            questionTexts: ["下一步做什么？"],
            isSending: false,
            pending: [],
            sessionID: "ses_1"
        ))
    }

    func testQuestionCardStaysLiveWhileItsRequestIsPending() {
        XCTAssertFalse(QuestionCardState.isExpired(
            tool: "question",
            status: "running",
            questionTexts: ["下一步做什么？"],
            isSending: false,
            pending: [pendingQuestion()],
            sessionID: "ses_1"
        ))
    }

    func testQuestionCardIgnoresIdenticalQuestionFromAnotherSession() {
        XCTAssertTrue(QuestionCardState.isExpired(
            tool: "question",
            status: "running",
            questionTexts: ["下一步做什么？"],
            isSending: false,
            pending: [pendingQuestion(sessionID: "ses_2")],
            sessionID: "ses_1"
        ))
    }

    func testQuestionCardNeverExpiresWhileSessionIsSending() {
        XCTAssertFalse(QuestionCardState.isExpired(
            tool: "question",
            status: "running",
            questionTexts: ["下一步做什么？"],
            isSending: true,
            pending: [],
            sessionID: "ses_1"
        ))
    }

    func testFinishedQuestionToolIsNotTreatedAsExpired() {
        XCTAssertFalse(QuestionCardState.isExpired(
            tool: "question",
            status: "completed",
            questionTexts: ["下一步做什么？"],
            isSending: false,
            pending: [],
            sessionID: "ses_1"
        ))
    }

    func testQuestionResultSummaryFromOutput() {
        let output = "User has answered your questions: \"下一步做什么？\"=\"继续开发\". You can now continue."
        let summary = QuestionCardState.resultSummary(output)
        XCTAssertEqual(summary, "User has answered your questions: \"下一步做什么？\"=\"继续开发\". You can now continue.")
    }

    func testQuestionDismissSummaryFromEscapedOutput() {
        XCTAssertEqual(
            QuestionCardState.resultSummary("User dismissed the question\\nno answer"),
            "User dismissed the question\nno answer"
        )
    }
}

extension ModelTests {
    func testExportEscapesUserMarkdownAndHandlesBackticksInMetadata() throws {
        let session = Session(id: "s_escape", title: "A *draft* #title", directory: "/tmp/with`tick", time: nil, revert: nil)
        let messages = [
            MessageRecord(
                info: MessageInfo(id: "msg_1", role: "user"),
                parts: [Part(id: "p1", type: "text", text: "Use `code` and *stars* <script>")]
            ),
        ]
        let markdown = TranscriptExporter.markdown(session: session, messages: messages)
        XCTAssertTrue(markdown.contains("# A \\*draft\\* \\#title"))
        XCTAssertTrue(markdown.contains("``with`tick``"))
        XCTAssertTrue(markdown.contains("Use \\`code\\` and \\*stars\\* \\<script\\>"))
    }
}
