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

@Suite struct CodeMapAcceptanceTests {
    private func clone(_ report: (URL) throws -> Void) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codemap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("graphify-out"), withIntermediateDirectories: true)
        try report(dir)
        return dir
    }

    @Test func readsTheReportAndCutsItAtTheLimit() throws {
        let dir = try clone { try String(repeating: "x", count: 70_000).write(to: $0.appendingPathComponent("graphify-out/GRAPH_REPORT.md"), atomically: true, encoding: .utf8) }
        #expect(NewIssues.codeMap(inClone: dir)?.count == 60_000)
    }

    @Test func noReportIsNoMap() throws {
        #expect(NewIssues.codeMap(inClone: try clone { _ in }) == nil)
    }

    @Test func aLinkOutOfTheCloneIsNeverFollowed() throws {
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString)")
        try "private key".write(to: secret, atomically: true, encoding: .utf8)
        let dir = try clone { try FileManager.default.createSymbolicLink(at: $0.appendingPathComponent("graphify-out/GRAPH_REPORT.md"), withDestinationURL: secret) }
        #expect(NewIssues.codeMap(inClone: dir) == nil)
    }
}

@Suite struct TurnNotesAcceptanceTests {
    @Test func theOwnerSeesTheReplyAndTheNextTurnGetsTheNotes() {
        let message = "Which provider?\n\n---notes---\nbilling is in gateway/src/billing.ts\nissue #12 overlaps"
        #expect(NewIssues.reply(from: message) == .questions("Which provider?"))
        #expect(NewIssues.notes(from: message) == "billing is in gateway/src/billing.ts\nissue #12 overlaps")
    }

    @Test func aReadyIssueKeepsNoNotesInItsBody() {
        let message = "## Ready\nTitle: Pay by WhatsApp\n\nBody text.\n---notes---\nchecked billing.ts"
        #expect(NewIssues.reply(from: message) == .ready(title: "Pay by WhatsApp", body: "Body text."))
        #expect(NewIssues.notes(from: message) == "checked billing.ts")
    }

    @Test func aReplyWithoutNotesIsUnchanged() {
        #expect(NewIssues.reply(from: "Just a question?") == .questions("Just a question?"))
        #expect(NewIssues.notes(from: "Just a question?") == nil)
    }

    @Test func notesAreAttachedToTheNextTurnOnly() throws {
        let request = NewIssues.Request(id: "1", repo: "o/r", turn: 2, conversation: "c", notes: "n")
        let candidate = try #require(NewIssues.candidate(request, issues: [], merged: [], agents: ["claude": AgentTemplate(argv: ["/usr/local/bin/claude", "-p"])],
                                                         defaultBranch: "main", me: "me"))
        #expect(candidate.attachments[NewIssues.notesFile] == "n")
    }
}

@Suite struct DraftModelAcceptanceTests {
    private let agents = ["claude": AgentTemplate(argv: ["/usr/local/bin/claude", "-p"])]

    @Test func aNewIssueTurnRunsOnTheChosenModelNotTheAgentsDefault() throws {
        let request = NewIssues.Request(id: "1", repo: "o/r", turn: 1, conversation: "c")
        let byDefault = try #require(NewIssues.candidate(request, issues: [], merged: [], agents: agents, defaultBranch: "main", me: "me"))
        #expect(byDefault.model == BtonConfig.defaultDraftModel)
        let chosen = try #require(NewIssues.candidate(request, issues: [], merged: [], agents: agents, defaultBranch: "main", me: "me",
                                                       model: "claude-opus-5-5"))
        #expect(chosen.model == "claude-opus-5-5")
    }

    @Test func theChoiceIsSavedInTheConfigAndAnOldConfigHasNone() throws {
        var config = BtonConfig.initial
        config.draftModel = "claude-opus-5-5"
        #expect(try JSONDecoder().decode(BtonConfig.self, from: JSONEncoder().encode(config)).draftModel == "claude-opus-5-5")
        #expect(try JSONDecoder().decode(BtonConfig.self, from: JSONEncoder().encode(BtonConfig.initial)).draftModel == nil)
    }
}
