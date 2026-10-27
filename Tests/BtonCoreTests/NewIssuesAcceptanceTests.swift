@testable import BtonCore
import Foundation
import Testing

@Suite struct NewIssuesAcceptanceTests {
    private let agents = ["claude": AgentTemplate(argv: ["/usr/local/bin/claude", "-p"])]

    private func issue(_ number: Int, _ title: String, labels: [String] = []) -> OpenIssue {
        OpenIssue(repo: "o/r", number: number, title: title, url: URL(string: "https://github.com/o/r/issues/\(number)")!,
                  createdAt: .now, author: "a", authorAssociation: "OWNER", body: "", comments: [], labels: labels)
    }

    @Test func aMessageWithTheMarkerTitleAndBodyIsTheIssue() {
        let reply = NewIssues.reply(from: "## Ready\nTitle: Export invoices as CSV\n\nWhy.\n\n- [ ] one\n")
        #expect(reply == .ready(title: "Export invoices as CSV", body: "Why.\n\n- [ ] one"))
    }

    @Test(arguments: [
        "Which format, CSV or XLSX?",
        "## Ready\nno title line\n\nbody",
        "## Ready\nTitle: \n\nbody",
        "## Ready\nTitle: T\n",
        "Some text first\n## Ready\nTitle: T\n\nbody",
    ])
    func anythingElseIsTheAgentTalking(message: String) {
        #expect(NewIssues.reply(from: message) == .questions(message.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func eachRoundIsItsOwnJobAndCarriesTheConversationAndWhatExists() throws {
        let request = NewIssues.Request(id: "ab12cd34", repo: "o/r", turn: 2, conversation: "## Owner\n\nexport csv")
        let candidate = try #require(NewIssues.candidate(request, issues: [issue(7, "Export", labels: ["stage:spec"])],
            merged: [], agents: agents, defaultBranch: "main", me: "me"))
        #expect(candidate.key == JobKey(repo: "o/r", item: "new-ab12cd34", move: "compose", head: "2"))
        #expect(candidate.key != NewIssues.Request(id: "ab12cd34", repo: "o/r", turn: 3, conversation: "").key)
        #expect(candidate.attachments["conversation.md"] == "## Owner\n\nexport csv")
        #expect(candidate.attachments["existing.md"]?.contains("- #7 Export [stage:spec]") == true)
        #expect(candidate.denied == Supervision.deniedTools)
        #expect(candidate.skipsChecks)
        #expect(!candidate.postComment)
        #expect(!(candidate.prompt ?? "").contains("export csv"))
    }

    @Test func aSessionsItemIsAValidLease() throws {
        let request = NewIssues.Request(id: NewIssues.newID(), repo: "o/r", turn: 1, conversation: "")
        #expect(LeaseItem(request.key.item) != nil)
    }

    @Test func aNonClaudeAgentStartsNothing() {
        let request = NewIssues.Request(id: "x", repo: "o/r", turn: 1, conversation: "")
        #expect(NewIssues.candidate(request, issues: [], merged: [], agents: ["claude": AgentTemplate(argv: ["/usr/bin/true"])],
                                    defaultBranch: "main", me: "me") == nil)
    }

    @Test func createIssuePassesTheBodyAsAFileAndEachLabelAndReturnsTheUrl() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gh = dir.appendingPathComponent("gh")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/argv\"\necho https://github.com/o/r/issues/12\n"
            .write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let body = dir.appendingPathComponent("body")
        try "secret body $(rm -rf /)".write(to: body, atomically: true, encoding: .utf8)
        let url = try await GitHubClient(ghPath: gh.path).createIssue(repo: "o/r", title: "--title; x", bodyFile: body,
                                                                       labels: ["priority:high", "stage:ready"])
        #expect(url.absoluteString == "https://github.com/o/r/issues/12")
        let argv = try String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(argv == ["issue", "create", "--repo", "o/r", "--title", "--title; x", "--body-file", body.path,
                         "--label", "priority:high", "--label", "stage:ready"])
        #expect(!argv.contains { $0.contains("secret body") })
    }
}
