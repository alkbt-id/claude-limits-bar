import XCTest
@testable import ClaudeLimits

final class ClaudeSessionTests: XCTestCase {
    func testEmptyVSCodeSessionIsHiddenButActualIdleConversationRemains() {
        for state in [LiveSession.State.idle, .stopped] {
            XCTAssertFalse(LiveSessionScanner.shouldShow(
                state: state, entrypoint: "claude-vscode", hasConversation: false
            ))
            XCTAssertTrue(LiveSessionScanner.shouldShow(
                state: state, entrypoint: "claude-vscode", hasConversation: true
            ))
        }
        XCTAssertTrue(LiveSessionScanner.shouldShow(
            state: .idle, entrypoint: "cli", hasConversation: false
        ))
        XCTAssertTrue(LiveSessionScanner.shouldShow(
            state: .idle, entrypoint: nil, hasConversation: false
        ))
        XCTAssertTrue(LiveSessionScanner.shouldShow(
            state: .idle, entrypoint: "claude-vscode", hasConversation: false, historyDisabled: true
        ))
    }

    func testWorkAndPromptsRemainVisibleWithoutTranscript() {
        for state in [LiveSession.State.working(tool: nil), .background, .question(plan: false),
                      .permission(detail: nil, sure: true)] {
            XCTAssertTrue(LiveSessionScanner.shouldShow(
                state: state, entrypoint: "claude-vscode", hasConversation: false
            ))
        }
    }

    func testTitlesMetaSidechainsAndSyntheticMessagesDoNotCreateConversation() throws {
        let (dir, url, tail) = try transcript()
        defer { try? FileManager.default.removeItem(at: dir) }
        let records: [[String: Any]] = [
            ["type": "custom-title", "customTitle": "Named empty tab"],
            ["type": "user", "isMeta": true, "message": ["content": "Setup"]],
            ["type": "assistant", "isSidechain": true, "message": ["content": "Sidechain"]],
            ["type": "user", "queueTranscriptOnly": true, "message": ["content": "Notice"]],
            ["type": "assistant", "message": ["model": "<synthetic>", "content": "Setup"]],
        ]
        try write(records, to: url)
        tail.update()
        XCTAssertFalse(tail.hasConversation)
    }

    func testFirstRealMessageCreatesConversationAndTruncationClearsEvidence() throws {
        let (dir, url, tail) = try transcript()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write([["type": "user", "message": ["content": "Hello"]]], to: url)
        tail.update()
        XCTAssertTrue(tail.hasConversation)
        try Data("{}\n".utf8).write(to: url)
        tail.update()
        XCTAssertFalse(tail.hasConversation)
    }

    func testRealAssistantAndImageInputAreConversationEvidence() throws {
        for record: [String: Any] in [
            ["type": "assistant", "message": ["content": [["type": "text", "text": "Done"]],
                                                  "stop_reason": "end_turn"]],
            ["type": "user", "message": ["content": [["type": "image"]]]],
        ] {
            let (dir, url, tail) = try transcript()
            defer { try? FileManager.default.removeItem(at: dir) }
            try write([record], to: url)
            tail.update()
            XCTAssertTrue(tail.hasConversation)
        }
    }

    func testRecordedLastPromptPreservesResumedConversation() throws {
        let (dir, url, tail) = try transcript()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write([["type": "last-prompt", "lastPrompt": "Previous task"]], to: url)
        tail.update()
        XCTAssertTrue(tail.hasConversation)
    }

    private func transcript() throws -> (URL, URL, TranscriptTail) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.jsonl")
        return (dir, url, TranscriptTail(url: url))
    }

    private func write(_ records: [[String: Any]], to url: URL) throws {
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(0x0A)
        }
        try data.write(to: url)
    }
}
