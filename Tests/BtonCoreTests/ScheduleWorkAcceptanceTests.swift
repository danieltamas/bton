@testable import BtonCore
import Foundation
import Testing

private enum ScheduleWorkFixture {
    static func line(_ blocks: [[String: Any]], type: String = "assistant") throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [
            "type": type, "message": ["content": blocks]
        ]), as: UTF8.self)
    }
    static func bash(_ command: String) -> [String: Any] {
        ["type": "tool_use", "name": "Bash", "input": ["command": command]]
    }
    static func data(_ commands: [String]) throws -> Data {
        Data(try commands.map { try line([bash($0)]) }.joined(separator: "\n").utf8)
    }
    static func fileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bton-schedule-work-\(UUID()).jsonl")
    }
}

struct ScheduleWorkAcceptanceTests {
    @Test func preservesFirstActionOrderWhileCurrentTracksLastAction() throws {
        let first = try ScheduleWorkFixture.line([ScheduleWorkFixture.bash("gh pr view 7")])
        let later = try ScheduleWorkFixture.line([
            ScheduleWorkFixture.bash("gh pr diff 9"), ScheduleWorkFixture.bash("gh pr checks 7"),
            ScheduleWorkFixture.bash("pwd")
        ])
        let data = Data("\(first)\n\(later)\n".utf8)
        #expect(SessionTranscript.pullRequests(in: data) == [7, 9])
        #expect(SessionTranscript.currentPullRequest(in: data) == 7)
    }

    @Test func recognizesSupportedCommandFormsAndSkipsFlagValues() throws {
        let verbs = ["view", "diff", "checks", "comment", "edit", "review", "merge",
                     "checkout", "ready", "close", "reopen"]
        var commands: [String] = []
        for (index, verb) in verbs.enumerated() {
            commands.append("gh pr \(verb) --limit 50 \(100 + index)")
            commands.append("gh pr \(verb) #\(100 + index)")
        }
        commands += ["scripts/wt merge 201", "scripts/wt merge #202",
                     "git fetch origin pull/203/head", "gh pr view --limit 50",
                     "gh pr list --limit 51", "gh pr create 52", "echo 53",
                     "gh issue view 54", "gh pr view | echo 55"]
        #expect(SessionTranscript.pullRequests(in: try ScheduleWorkFixture.data(commands))
                == Array(100...110) + [201, 202, 203])
    }

    @Test func ignoresPromptsTextThinkingResultsAndOtherTools() throws {
        let quote = "gh pr view 999; scripts/wt merge 998; git fetch origin pull/997/head"
        let prompt = String(decoding: try JSONSerialization.data(withJSONObject: [
            "type": "user", "message": ["content": quote]
        ]), as: UTF8.self)
        let blocks: [[String: Any]] = [
            ["type": "text", "text": quote],
            ["type": "thinking", "thinking": quote],
            ["type": "tool_result", "content": quote],
            ["type": "tool_result", "content": [["type": "text", "text": quote]]],
            ["type": "tool_use", "name": "Read", "input": ["command": quote]],
            ["type": "tool_use", "name": "Write", "input": ["content": quote]],
            ["type": "tool_use", "name": "Bash", "input": ["description": quote]]
        ]
        let data = Data("\(prompt)\n\(try ScheduleWorkFixture.line(blocks))\n".utf8)
        #expect(SessionTranscript.pullRequests(in: data).isEmpty)
    }

    @Test func skipsMalformedLinesAndHandlesEmptyTranscript() throws {
        let first = try ScheduleWorkFixture.line([ScheduleWorkFixture.bash("gh pr view 7")])
        let last = try ScheduleWorkFixture.line([ScheduleWorkFixture.bash("gh pr view 9")])
        let data = Data("not json gh pr view 999\n\(first)\n{broken\n\n\(last)".utf8)
        #expect(SessionTranscript.pullRequests(in: data) == [7, 9])
        #expect(SessionTranscript.pullRequests(in: Data()).isEmpty)
        #expect(SessionTranscript.pullRequests(in: Data("invalid".utf8)).isEmpty)
    }

    @Test func fileEntryPointReadsWholeTranscriptBeyondDisplayAndTailLimits() throws {
        let file = ScheduleWorkFixture.fileURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let first = try ScheduleWorkFixture.line([ScheduleWorkFixture.bash("gh pr view 7")])
        let padding = try ScheduleWorkFixture.line([["type": "text", "text": String(repeating: "x", count: 1400)]])
        let last = try ScheduleWorkFixture.line([ScheduleWorkFixture.bash("gh pr view 9")])
        let data = Data(([first] + Array(repeating: padding, count: 450) + [last]).joined(separator: "\n").utf8)
        try data.write(to: file)
        #expect(SessionTranscript.pullRequests(in: data) == [7, 9])
        #expect(SessionTranscript.pullRequests(ofSessionFile: file) == [7, 9])
    }

    @Test func missingAndUnreadableFilesReturnEmpty() throws {
        #expect(SessionTranscript.pullRequests(ofSessionFile: ScheduleWorkFixture.fileURL()).isEmpty)
        let directory = ScheduleWorkFixture.fileURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SessionTranscript.pullRequests(ofSessionFile: directory).isEmpty)
    }
}
