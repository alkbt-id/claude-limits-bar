import XCTest
@testable import ClaudeLimits

final class CodexTests: XCTestCase {
    private let id = "00000000-0000-4000-8000-000000000001"
    private let other = "00000000-0000-4000-8000-000000000002"

    func testWeeklyPrimaryIsNotFiveHourWindow() throws {
        let snapshot = try CodexAPI.parse([
            "rateLimits": ["planType": "prolite", "primary": window(42, minutes: 10080)],
        ])
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.sevenDay?.utilization, 42)
        XCTAssertEqual(snapshot.codexPlan, "prolite")
        XCTAssertNil(snapshot.ordinaryUsageAllowed)
    }

    func testCodexBucketWinsAndDurationDeterminesWindow() throws {
        let snapshot = try CodexAPI.parse([
            "rateLimits": ["primary": window(99, minutes: 300)],
            "rateLimitsByLimitId": ["codex": [
                "primary": window(14, minutes: 10080),
                "secondary": window(27, minutes: 300),
            ]],
            "ordinaryUsageAllowed": false,
        ])
        XCTAssertEqual(snapshot.fiveHour?.utilization, 27)
        XCTAssertEqual(snapshot.sevenDay?.utilization, 14)
        XCTAssertEqual(snapshot.ordinaryUsageAllowed, false)
        XCTAssertEqual(snapshot.sevenDay?.resetsAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testMalformedResultFailsInsteadOfInventingLimits() {
        XCTAssertThrowsError(try CodexAPI.parse([:]))
        let snapshot = try? CodexAPI.parse(["rateLimits": ["primary": NSNull()]])
        XCTAssertNotNil(snapshot)
        XCTAssertNil(snapshot?.fiveHour)
        XCTAssertNil(snapshot?.sevenDay)
    }

    func testDesktopDeepLinkOnlyTargetsVerifiedHostAndSessionID() {
        XCTAssertEqual(CodexScanner.openURL(session: id, host: .other(bundleID: "com.openai.codex"))?.absoluteString,
                       "codex://threads/\(id)")
        XCTAssertNil(CodexScanner.openURL(session: "../../new", host: .other(bundleID: "com.openai.codex")))
        XCTAssertNil(CodexScanner.openURL(session: id, host: .other(bundleID: "com.microsoft.VSCode")))
        XCTAssertNil(CodexScanner.openURL(session: id, host: .terminal(bundleID: "com.apple.Terminal")))
    }

    func testVSCodeCodexLinkTargetsExactChatAndExistingWindow() throws {
        let url = try XCTUnwrap(Navigator.codexVSCodeURL(
            sessionID: id, bundleID: "com.microsoft.VSCode", windowID: 5
        ))
        XCTAssertEqual(url.absoluteString, "vscode://openai.chatgpt/local/\(id)?windowId=5")
        XCTAssertEqual(Navigator.codexVSCodeURL(
            sessionID: id, bundleID: "com.microsoft.VSCodeInsiders", windowID: 2
        )?.scheme, "vscode-insiders")
    }

    func testVSCodeCodexLinkRequiresKnownWindowHostAndValidSession() {
        XCTAssertNil(Navigator.codexVSCodeURL(sessionID: id, bundleID: "com.microsoft.VSCode", windowID: nil))
        XCTAssertNil(Navigator.codexVSCodeURL(sessionID: id, bundleID: "com.microsoft.VSCode", windowID: 0))
        XCTAssertNil(Navigator.codexVSCodeURL(sessionID: id, bundleID: "com.apple.Terminal", windowID: 5))
        XCTAssertNil(Navigator.codexVSCodeURL(sessionID: "../new", bundleID: "com.microsoft.VSCode", windowID: 5))
    }

    func testUsageRecordsDeduplicateResponsesAndDoNotDoubleCountCachedOrReasoningTokens() throws {
        let tail = makeTail()
        let usage: [String: Any] = [
            "thread_id": id, "response_id": "response-1",
            "usage": ["input_tokens": 100, "cached_input_tokens": 90,
                      "output_tokens": 20, "reasoning_output_tokens": 15],
        ]
        try feed(tail, "token_usage_record", usage)
        try feed(tail, "token_usage_record", usage)
        try feed(tail, "token_usage_record", [
            "thread_id": other, "response_id": "foreign", "usage": ["total_tokens": 9999],
        ])
        XCTAssertEqual(tail.hourly.values.reduce(0, +), 120)
    }

    func testLegacyCumulativeCountersOnlyAddDeltas() throws {
        let tail = makeTail()
        for count in [100, 100, 130] {
            try feed(tail, "event_msg", ["type": "token_count", "info": [
                "total_token_usage": ["total_tokens": count],
            ]])
        }
        XCTAssertEqual(tail.hourly.values.reduce(0, +), 130)
    }

    func testQuestionToolOutputAndTurnCompletionTransitions() throws {
        let tail = makeTail()
        try feed(tail, "event_msg", ["type": "task_started"])
        XCTAssertTrue(tail.isWorking)
        try feed(tail, "response_item", ["type": "function_call", "call_id": "q",
                                          "name": "request_user_input", "arguments": "{}"])
        XCTAssertEqual(tail.state, .question(plan: false))
        try feed(tail, "response_item", ["type": "function_call_output", "call_id": "q"])
        XCTAssertTrue(tail.isWorking)
        try feed(tail, "event_msg", ["type": "task_complete"])
        XCTAssertEqual(tail.state, .idle)
        try feed(tail, "event_msg", ["type": "turn_aborted"])
        XCTAssertEqual(tail.state, .stopped)
    }

    func testLiveBackgroundCommandSurvivesToolReturnAndTurnCompletion() throws {
        let tail = makeTail()
        try feed(tail, "event_msg", ["type": "task_started"])
        try feed(tail, "response_item", ["type": "function_call", "call_id": "shell",
                                          "name": "exec_command", "arguments": "{\"cmd\":\"sleep 60\"}"])
        try feed(tail, "response_item", ["type": "function_call_output", "call_id": "shell",
                                          "output": "Process running with session ID 42"])
        try feed(tail, "event_msg", ["type": "task_complete"])
        XCTAssertEqual(CodexScanner.liveState(base: tail.state, agents: 0, commands: 1), .background)
        XCTAssertEqual(CodexScanner.liveState(base: tail.state, agents: 0, commands: 0), .idle)
        XCTAssertEqual(CodexScanner.liveState(base: .stopped, agents: 0, commands: 1), .background)
    }

    func testBackgroundWorkDoesNotHideExplicitQuestionOrPermission() {
        for state in [LiveSession.State.question(plan: false), .permission(detail: nil, sure: true)] {
            XCTAssertEqual(CodexScanner.liveState(base: state, agents: 1, commands: 1), state)
        }
        XCTAssertEqual(CodexScanner.liveState(base: .idle, agents: 1, commands: 0), .background)
    }

    func testNativeProcessWithoutThreadEnvironmentMatchesItsRecordedLaunch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["3"]
        process.environment = [:]
        let launchedAt = Date()
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let info = try XCTUnwrap(Proc.info(process.processIdentifier))
        XCTAssertNil(Proc.environment(process.processIdentifier)?["CODEX_THREAD_ID"])
        let request = CodexShellRequest(threadID: id, command: "/bin/sleep 3",
                                        startedAt: launchedAt, endedAt: Date())
        XCTAssertEqual(CodexScanner.matchNativeCommand(
            commandLine: Proc.commandLine(process.processIdentifier), startedAt: Proc.startTime(info),
            requests: [request]
        ), id)
    }

    func testNativeCommandMatchingRejectsAmbiguityWrongArgsAndWrongTime() {
        let at = Date()
        let first = CodexShellRequest(threadID: id, command: "/bin/sleep 91",
                                      startedAt: at, endedAt: at.addingTimeInterval(1))
        let second = CodexShellRequest(threadID: other, command: "/bin/sleep 91",
                                       startedAt: at, endedAt: at.addingTimeInterval(1))
        XCTAssertNil(CodexScanner.matchNativeCommand(commandLine: "sleep 91", startedAt: at,
                                                    requests: [first, second]))
        XCTAssertNil(CodexScanner.matchNativeCommand(commandLine: "sleep 9", startedAt: at,
                                                    requests: [first]))
        XCTAssertNil(CodexScanner.matchNativeCommand(commandLine: "sleep 91",
                                                    startedAt: at.addingTimeInterval(20), requests: [first]))
    }

    func testCodeRunnerRetainsLiteralLaunchAfterToolAndTurnEnd() throws {
        let tail = makeTail()
        let code = #"text(await tools.exec_command({cmd:"/bin/sleep 77",yield_time_ms:1000}));"#
        try feed(tail, "response_item", ["type": "custom_tool_call", "call_id": "runner",
                                          "name": "functions.exec", "input": code])
        try feed(tail, "response_item", ["type": "custom_tool_call_output", "call_id": "runner"])
        try feed(tail, "event_msg", ["type": "task_complete"])
        XCTAssertEqual(tail.shellRequests.map(\.command), ["/bin/sleep 77"])
        XCTAssertEqual(tail.shellRequests.first?.threadID, id)
        XCTAssertNotNil(tail.shellRequests.first?.endedAt)
    }

    func testCodeRunnerOnlyExtractsRealLiteralCalls() {
        let code = #"""
        // tools.exec_command({cmd:"sleep 999"})
        const example = 'tools.exec_command({cmd:"sleep 998"})';
        text(await tools.exec_command({cmd:"/bin/sleep 77",yield_time_ms:1000}));
        await tools.exec_command({cmd:'echo done'});
        """#
        XCTAssertEqual(CodexTranscriptTail.literalCommands(in: code), ["/bin/sleep 77", "echo done"])
    }

    func testForeignForkContextDoesNotOverwriteOwnMetadataOrState() throws {
        let tail = makeTail()
        try feed(tail, "session_meta", ["id": id, "cwd": "/own", "source": "cli"])
        try feed(tail, "session_meta", ["id": other, "cwd": "/foreign", "source": "cli"])
        try feed(tail, "event_msg", ["type": "task_started"])
        XCTAssertEqual(tail.cwd, "/own")
        XCTAssertEqual(tail.state, .idle)
        try feed(tail, "event_msg", ["type": "thread_settings_applied", "thread_id": id])
        try feed(tail, "event_msg", ["type": "task_started"])
        XCTAssertTrue(tail.isWorking)
    }

    func testOpenDescriptorsDetermineSessionsAndOldLockFilesAreIrrelevant() {
        let root = URL(fileURLWithPath: "/tmp/codex-fixture")
        let rollout = root.appendingPathComponent("sessions/rollout-\(id).jsonl")
        let text = """
        p123
        n/tmp/codex-fixture/thread-writer-locks/\(id).lock
        n\(rollout.path)
        n/tmp/foreign/sessions/rollout-\(other).jsonl
        p456
        n/tmp/codex-fixture/thread-writer-locks/\(other).lock
        """
        let writers = CodexScanner.parseOpenFiles(text, root: root)
        XCTAssertEqual(writers.map(\.pid), [123, 456])
        XCTAssertEqual(writers[0].sessions.count, 1)
        XCTAssertEqual(writers[0].sessions[id]!, rollout)
        XCTAssertTrue(writers[1].sessions.keys.contains(other))
        XCTAssertNil(writers[1].sessions[other]!)
        XCTAssertTrue(CodexScanner.parseOpenFiles("", root: root).isEmpty)
    }

    func testIncrementalReaderWaitsForFullLineAndHandlesTruncation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout-\(id).jsonl")
        let tail = CodexTranscriptTail(url: url, id: id)
        let data = try line("event_msg", ["type": "task_started"])
        try data.write(to: url)
        tail.update()
        XCTAssertEqual(tail.state, .idle)
        var completed = data
        completed.append(0x0A)
        try completed.write(to: url)
        tail.update()
        XCTAssertTrue(tail.isWorking)
        try Data("{}\n".utf8).write(to: url)
        tail.update()
        XCTAssertEqual(tail.state, .idle)
    }

    @MainActor
    func testMenuOnlyIncludesRunningAgents() {
        let claude = AppModel(store: SampleStore(samples: []))
        let codex = AppModel(agent: .codex, store: SampleStore(samples: []))
        let agents = AgentsModel(claude: claude, codex: codex)
        XCTAssertTrue(agents.active.isEmpty)
        codex.isRunning = true
        XCTAssertEqual(agents.active.map(\.agent), [.codex])
        claude.isRunning = true
        XCTAssertEqual(agents.active.map(\.agent), [.claude, .codex])
        codex.isRunning = false
        XCTAssertEqual(agents.active.map(\.agent), [.claude])
        XCTAssertNotEqual(AgentKind.claude.settingsKey("sessionReadAt"),
                          AgentKind.codex.settingsKey("sessionReadAt"))
    }

    @MainActor
    func testDismissedIdleSessionReturnsForNewWorkAndFreshCompletion() {
        let model = AppModel(agent: .codex, store: SampleStore(samples: []))
        var session = LiveSession(id: id, pid: 1, title: "Old chat", cwd: "/project",
                                  entrypoint: "codex", state: .idle,
                                  since: Date().addingTimeInterval(-3600), agentNames: [], commandLines: [],
                                  host: .other(bundleID: "com.microsoft.VSCode"), hostPID: nil, tty: nil)
        model.live = [session]
        model.hideSession(session)
        XCTAssertTrue(model.live.isEmpty)
        XCTAssertFalse(model.shouldShow(session))
        session.state = .working(tool: nil)
        XCTAssertTrue(model.shouldShow(session))
        session.state = .question(plan: false)
        XCTAssertTrue(model.shouldShow(session))
        session.state = .idle
        session.since = Date().addingTimeInterval(1)
        XCTAssertTrue(model.shouldShow(session))
    }

    private func window(_ percent: Int, minutes: Int) -> [String: Any] {
        ["usedPercent": percent, "windowDurationMins": minutes, "resetsAt": 2_000_000_000]
    }
    private func makeTail() -> CodexTranscriptTail {
        CodexTranscriptTail(url: URL(fileURLWithPath: "/tmp/unused"), id: id)
    }
    private func line(_ type: String, _ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-11-26T12:00:00Z", "type": type, "payload": payload,
        ])
    }
    private func feed(_ tail: CodexTranscriptTail, _ type: String, _ payload: [String: Any]) throws {
        tail.consume(try line(type, payload))
    }
}
