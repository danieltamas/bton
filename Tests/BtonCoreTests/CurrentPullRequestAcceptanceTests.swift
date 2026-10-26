@testable import BtonCore
import Foundation
import Testing

private enum CurrentPullRequestFixture {
    static func commandLine(_ command: String) throws -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "message": ["content": [[
                "type": "tool_use", "name": "Bash", "input": ["command": command]
            ]]]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func fileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-current-pr-\(UUID()).jsonl")
    }
}

@Suite(ProcessBound())
struct CurrentPullRequestAcceptanceTests {
    @Test func recognizesEverySupportedGitHubPullRequestVerb() {
        for verb in ["view", "diff", "checks", "comment", "edit", "review", "merge",
                     "checkout", "ready", "close", "reopen"] {
            #expect(SessionTranscript.pullRequest(inCommand: "gh pr \(verb) 339") == 339)
            #expect(SessionTranscript.pullRequest(inCommand: "gh pr \(verb) #339") == 339)
        }
    }

    @Test func selectsFirstDigitArgumentAndSkipsFlagValues() {
        let cases: [(String, Int?)] = [
            ("gh pr view 342 --json body", 342),
            ("gh pr comment 339 --body-file f.md", 339),
            ("gh pr view -R o/r 12", 12),
            ("gh pr view --limit 5", nil),
            ("gh pr view --limit 5 342 343", 342),
            ("gh pr view --limit #5 #342", 342),
            ("gh pr view 12abc 3.5 +7 -8 # 349", 349),
            ("gh pr view", nil)
        ]
        for (command, expected) in cases {
            #expect(SessionTranscript.pullRequest(inCommand: command) == expected)
        }
    }

    @Test func stopsArgumentsAtEachShellSeparator() {
        for separator in ["|", ";", "&&", "||"] {
            #expect(SessionTranscript.pullRequest(inCommand: "gh pr view \(separator) head -5") == nil)
            #expect(SessionTranscript.pullRequest(inCommand: "gh pr view \(separator) echo 339") == nil)
            #expect(SessionTranscript.pullRequest(inCommand: "gh pr view 342 \(separator) echo 339") == 342)
        }
    }

    @Test func recognizesWorktreeMergeAndPullHeadReferences() {
        let cases: [(String, Int)] = [
            ("bash /x/scripts/wt merge 344", 344),
            ("scripts/wt merge #7", 7),
            ("customwt merge 345", 345),
            ("git fetch origin pull/351/head", 351),
            ("echo https://example.invalid/pull/352/head", 352)
        ]
        for (command, expected) in cases {
            #expect(SessionTranscript.pullRequest(inCommand: command) == expected)
        }
    }

    @Test func rejectsUnrelatedCommandsAndUnsupportedVerbs() {
        for command in ["", "gh issue view 12", "echo 339", "gh pr list --limit 50",
                        "gh pr create 339", "scripts/wt checkout 339", "gh pr view 339abc"] {
            #expect(SessionTranscript.pullRequest(inCommand: command) == nil)
        }
    }

    @Test func usesLastMatchingToolUseInFileAndBlockOrder() throws {
        let first = try CurrentPullRequestFixture.commandLine("gh pr view 900")
        let last = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr diff 342"}},{"type":"tool_use","name":"Bash","input":{"command":"gh pr checks 7"}},{"type":"tool_use","name":"Bash","input":{"command":"pwd"}},{"type":"text","text":"PR #999: gh pr view 999"}]}}"#
        let trailing = try CurrentPullRequestFixture.commandLine("gh pr list --limit 50")
        #expect(SessionTranscript.currentPullRequest(in: Data("\(first)\n\(last)\n\(trailing)\n".utf8)) == 7)
    }

    @Test func ignoresTextMentionsAndReturnsNilWithoutMatchingCommands() throws {
        let text = #"{"type":"assistant","message":{"content":[{"type":"text","text":"gh pr view 339 and pull/351/head"}]}}"#
        let command = try CurrentPullRequestFixture.commandLine("echo 339")
        #expect(SessionTranscript.currentPullRequest(in: Data("\(text)\n\(command)\n".utf8)) == nil)
        #expect(SessionTranscript.currentPullRequest(in: Data()) == nil)
    }

    @Test func skipsMalformedFirstLineAndReadsLaterCompleteLines() throws {
        let complete = try CurrentPullRequestFixture.commandLine("git fetch origin pull/351/head")
        let transcript = "input\":{\"command\":\"gh pr view 999\"}}]}}\n\(complete)\n"
        #expect(SessionTranscript.currentPullRequest(in: Data(transcript.utf8)) == 351)
    }

    @Test func fileEntryPointReadsTranscriptWithDefaultTail() throws {
        let file = CurrentPullRequestFixture.fileURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let line = try CurrentPullRequestFixture.commandLine("gh pr comment 339 --body-file f.md")
        try Data("\(line)\n".utf8).write(to: file)
        #expect(SessionTranscript.currentPullRequest(ofSessionFile: file) == 339)
    }

    @Test func excludesCommandsEntirelyBeforeRequestedTail() throws {
        let file = CurrentPullRequestFixture.fileURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let old = try CurrentPullRequestFixture.commandLine("gh pr view 339")
        let suffix = try CurrentPullRequestFixture.commandLine("pwd") + "\n"
        try Data("\(old)\n\(suffix)".utf8).write(to: file)
        #expect(SessionTranscript.currentPullRequest(ofSessionFile: file, tail: suffix.utf8.count) == nil)
    }

    @Test func skipsLineCutByTailAndKeepsLaterCompleteCommands() throws {
        let file = CurrentPullRequestFixture.fileURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let cut = try CurrentPullRequestFixture.commandLine("gh pr view 999")
        let complete = try CurrentPullRequestFixture.commandLine("scripts/wt merge #7")
        let suffix = try CurrentPullRequestFixture.commandLine("pwd")
        let laterLines = "\n\(complete)\n\(suffix)\n"
        try Data("\(cut)\(laterLines)".utf8).write(to: file)
        let tail = cut.utf8.count / 2 + laterLines.utf8.count
        #expect(SessionTranscript.currentPullRequest(ofSessionFile: file, tail: tail) == 7)
    }

    @Test func missingSessionFileReturnsNil() {
        #expect(SessionTranscript.currentPullRequest(ofSessionFile: CurrentPullRequestFixture.fileURL()) == nil)
    }
}
