import XCTest
@testable import ClaudeLimits

final class CodexViewActivityTests: XCTestCase {
    private let id = "00000000-0000-4000-8000-000000000001"

    func testExplicitViewActivityOnlyHidesInactiveFinishedSessions() {
        XCTAssertFalse(CodexViewActivity.shouldShow(state: .idle, active: false))
        XCTAssertFalse(CodexViewActivity.shouldShow(state: .stopped, active: false))
        for state in [LiveSession.State.working(tool: nil), .background, .question(plan: false),
                      .permission(detail: nil, sure: true)] {
            XCTAssertTrue(CodexViewActivity.shouldShow(state: state, active: false))
        }
        XCTAssertTrue(CodexViewActivity.shouldShow(state: .idle, active: nil))
        XCTAssertTrue(CodexViewActivity.shouldShow(state: .idle, active: true))
    }

    func testParserRequiresExplicitExtensionEventAndValidThreadID() throws {
        let event = try XCTUnwrap(CodexViewActivity.event(line(active: false)))
        XCTAssertEqual(event.sessionID, id)
        XCTAssertFalse(event.active)
        XCTAssertNil(CodexViewActivity.event("2026-11-26 08:05:17.632 [info] tool quoted " + line(active: false)))
        XCTAssertNil(CodexViewActivity.event(line(active: false).replacingOccurrences(of: id, with: "invalid")))
        XCTAssertNil(CodexViewActivity.event("unrelated log entry"))
    }

    func testIncrementalLogWaitsForNewlineAndIgnoresEarlierProcessLifetime() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Codex.log")
        let scanner = CodexViewActivity()
        let at = try XCTUnwrap(CodexViewActivity.event(line(active: false))?.at)
        let first = line(active: false) + "\n"
        try Data(first.utf8).write(to: url)
        XCTAssertEqual(scanner.update(log: url, since: at)[id], false)
        let partial = first + line(active: true)
        try Data(partial.utf8).write(to: url)
        XCTAssertEqual(scanner.update(log: url, since: at)[id], false)
        try Data((partial + "\n").utf8).write(to: url)
        XCTAssertEqual(scanner.update(log: url, since: at)[id], true)
        XCTAssertNil(scanner.update(log: url, since: at.addingTimeInterval(60))[id])
        try Data("unrelated\n".utf8).write(to: url)
        XCTAssertNil(scanner.update(log: url, since: at)[id])
    }

    func testResolverUsesCurrentAppLaunchAndExactExtensionHostLifetime() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let at = try XCTUnwrap(CodexViewActivity.event(line(active: false))?.at)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd'T'HHmmss"
        let current = root.appendingPathComponent(format.string(from: at))
        let old = root.appendingPathComponent(format.string(from: at.addingTimeInterval(-3600)))
        let renderer = "2026-11-26 08:05:17.632 [info] Started local extension host with pid 42.\n"
        for folder in [current.appendingPathComponent("window2"), old.appendingPathComponent("window9")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(renderer.utf8).write(to: folder.appendingPathComponent("renderer.log"))
        }
        let expected = current.appendingPathComponent("window2/exthost/openai.chatgpt/Codex.log")
        try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: expected)
        let actual = CodexViewActivity.logURL(logsRoot: root, launchedAt: at,
                                              extensionHostPID: 42, extensionHostStartedAt: at)
        XCTAssertEqual(actual?.resolvingSymlinksInPath(), expected.resolvingSymlinksInPath())
        let delayed = CodexViewActivity.logURL(logsRoot: root, launchedAt: at.addingTimeInterval(-3),
                                               extensionHostPID: 42, extensionHostStartedAt: at)
        XCTAssertEqual(delayed?.resolvingSymlinksInPath(), expected.resolvingSymlinksInPath())
        XCTAssertNil(CodexViewActivity.logURL(logsRoot: root, launchedAt: at,
                                             extensionHostPID: 7, extensionHostStartedAt: at))
        XCTAssertNil(CodexViewActivity.logURL(logsRoot: root, launchedAt: at,
                                             extensionHostPID: 42, extensionHostStartedAt: at.addingTimeInterval(60)))
    }

    private func line(active: Bool) -> String {
        "2026-11-26 08:05:17.632 [info] [extension-app-server-manager] thread_stream_view_activity_changed active=\(active) conversationId=\(id) historyAttached=true resumeState=resumed"
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
