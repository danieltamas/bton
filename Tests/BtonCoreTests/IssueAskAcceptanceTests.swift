@testable import BtonCore
import Foundation
import Testing

private enum IssueAskFixture {
    static let repo = "synthetic/project"
    static let title = "ISSUE_TITLE_DATA"
    static let body = "ISSUE_BODY_DATA @owner which option?"
    static let question = "COMMENT_DATA @owner choose A or B?"
    static func date(_ second: Int) -> Date { Date(timeIntervalSince1970: 1_792_368_000 + Double(second)) }
    static func comment(_ id: String = "21", author: String? = "teammate",
                        association: String? = "MEMBER", body: String = question,
                        second: Int = 1, url: URL? = URL(string: "https://example.invalid/issues/7#issuecomment-21")) -> IssueComment {
        IssueComment(id: id, author: author, authorAssociation: association,
                     body: body, createdAt: date(second), url: url)
    }
    static func issue(body: String = body, author: String? = "teammate", association: String = "OWNER",
                      comments: [IssueComment] = [], number: Int = 7) -> OpenIssue {
        OpenIssue(repo: repo, number: number, title: title,
                  url: URL(string: "https://example.invalid/issues/\(number)")!, createdAt: date(0),
                  author: author, authorAssociation: association, body: body, comments: comments)
    }
    static let agents = ["claude": AgentTemplate(argv: ["claude", "-p", "{prompt}"])]
    static func candidate(_ issue: OpenIssue, ask: IssueAsk? = nil,
                          agents: [String: AgentTemplate] = agents, branch: String = "main") throws -> DispatchCandidate? {
        let ask = try ask ?? #require(IssueAsks.ask(in: issue, me: "owner"))
        return IssueDrafts.candidate(ask: ask, issue: issue, agents: agents, defaultBranch: branch, me: "owner")
    }

    // Shaped from the spec's GitHub GraphQL query, not captured from a live repository.
    static func payload(_ issues: [OpenIssue]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        let nodes: [[String: Any]] = issues.map { issue in
            ["number": issue.number, "title": issue.title, "url": issue.url.absoluteString,
             "createdAt": formatter.string(from: issue.createdAt), "body": issue.body,
             "author": issue.author.map { ["login": $0] } as Any? ?? NSNull(),
             "authorAssociation": issue.authorAssociation,
             "comments": ["nodes": issue.comments.map { comment -> [String: Any] in
                 ["databaseId": Int(comment.id)!, "author": comment.author.map { ["login": $0] } as Any? ?? NSNull(),
                  "authorAssociation": comment.authorAssociation as Any? ?? NSNull(), "body": comment.body,
                  "createdAt": formatter.string(from: comment.createdAt),
                  "url": comment.url?.absoluteString as Any? ?? NSNull()]
             }]]
        }
        return try JSONSerialization.data(withJSONObject: ["data": ["repository": ["issues": ["nodes": nodes]]]])
    }
}

@Suite(ProcessBound())
struct IssueAskAcceptanceTests {
    @Test(arguments: [
        ("@owner", true), ("hello @OwNeR!", true), ("(@owner)", true),
        ("a@owner", false), ("1@owner", false), ("_@owner", false),
        ("-@owner", false), ("/@owner", false), ("email@owner.example", false),
        ("@owner2", false), ("@owner_name", false), ("@owner-name", false),
        ("@owners", false), ("@someone", false), ("`@owner`", false),
        ("``code @owner here``", false), ("```\n@owner\n```", false),
        ("```swift\n@owner\n```\n@OWNER", true), ("`@someone` @owner", true),
        ("https://example.invalid/@owner", false), ("@owner/path", true)
    ])
    func mentionsTable(text: String, expected: Bool) {
        #expect(IssueAsks.mentions(text, login: "owner") == expected)
    }

    @Test func latestTrustedAskWinsInTimeOrder() throws {
        let older = IssueAskFixture.comment("21", second: 1)
        let newer = IssueAskFixture.comment("22", author: "collaborator", association: "COLLABORATOR", second: 3)
        let issue = IssueAskFixture.issue(comments: [newer, older])
        let ask = try #require(IssueAsks.ask(in: issue, me: "OWNER"))
        #expect(ask.id == "synthetic/project#7")
        #expect(ask.repo == issue.repo && ask.number == issue.number && ask.title == issue.title)
        #expect(ask.commentID == "22" && ask.asker == "collaborator")
        #expect(ask.askedAt == newer.createdAt && ask.url == newer.url)
        let earlierIssue = IssueAskFixture.issue(number: 8)
        #expect(IssueAsks.asks([earlierIssue, issue], me: "owner").map(\.number) == [7, 8])
    }

    @Test func laterOwnerEntryClearsAskButNewQuestionRestoresIt() {
        let reply = IssueAskFixture.comment("22", author: "OwNeR", body: "Answer", second: 2)
        #expect(IssueAsks.ask(in: IssueAskFixture.issue(comments: [IssueAskFixture.comment(), reply]), me: "owner") == nil)
        let renewed = IssueAskFixture.comment("23", second: 3)
        #expect(IssueAsks.ask(in: IssueAskFixture.issue(comments: [reply, renewed]), me: "owner")?.commentID == "23")
    }

    @Test(arguments: [Optional("NONE"), "CONTRIBUTOR", "FIRST_TIMER", nil])
    func untrustedAndUnknownAuthorsIgnored(association: String?) {
        let issue = IssueAskFixture.issue(comments: [IssueAskFixture.comment(association: association)])
        #expect(IssueAsks.ask(in: issue, me: "owner")?.commentID == "body")
        let noBodyAsk = IssueAskFixture.issue(body: "No question", comments: issue.comments)
        #expect(IssueAsks.ask(in: noBodyAsk, me: "owner") == nil)
    }

    @Test func bodyFallbackOtherMentionOwnMentionAndDeletedAuthor() throws {
        let issue = IssueAskFixture.issue()
        let ask = try #require(IssueAsks.ask(in: issue, me: "owner"))
        #expect(ask.commentID == "body" && ask.url == issue.url && ask.askedAt == issue.createdAt)
        #expect(IssueAsks.ask(in: IssueAskFixture.issue(body: "@other?"), me: "owner") == nil)
        #expect(IssueAsks.ask(in: IssueAskFixture.issue(author: "OWNER"), me: "owner") == nil)
        #expect(IssueAsks.ask(in: IssueAskFixture.issue(author: nil), me: "owner") == nil)
        let fallback = IssueAskFixture.issue(comments: [IssueAskFixture.comment(url: nil)])
        #expect(IssueAsks.ask(in: fallback, me: "owner")?.url == fallback.url)
    }

    @Test func decodeSpecShapedGraphQLPayload() throws {
        let issue = IssueAskFixture.issue(comments: [IssueAskFixture.comment(),
            IssueAskFixture.comment("22", author: nil, association: nil, body: "Deleted account", second: 2, url: nil)])
        let decoded = try GitHubClient.decodeOpenIssues(IssueAskFixture.payload([issue]), repo: issue.repo)
        #expect(decoded == [issue])
        #expect(try GitHubClient.decodeOpenIssues(IssueAskFixture.payload([]), repo: issue.repo).isEmpty)
        #expect(throws: (any Error).self) {
            try GitHubClient.decodeOpenIssues(Data("not json".utf8), repo: issue.repo)
        }
    }

    @Test func threadContainsTitleBodyAuthorsTimesAndEveryComment() {
        let issue = IssueAskFixture.issue(comments: [IssueAskFixture.comment(),
            IssueAskFixture.comment("22", author: "second-person", body: "SECOND_COMMENT", second: 2)])
        let thread = IssueDrafts.thread(issue)
        for text in [issue.title, issue.body, IssueAskFixture.question, "SECOND_COMMENT", "teammate", "second-person"] {
            #expect(thread.contains(text))
        }
        // Exact Markdown headings and timestamp formatting are deliberately unspecified.
        #expect(thread.contains("2026"))
    }

    @Test func candidateFieldsKeepThreadOutOfPromptAndKeyEachComment() throws {
        let issue = IssueAskFixture.issue(comments: [IssueAskFixture.comment()])
        let c = try #require(try IssueAskFixture.candidate(issue))
        #expect(IssueDrafts.move == "draft" && IssueDrafts.defaultAgent == "claude")
        #expect(IssueDrafts.timeoutMinutes == 15 && IssueDrafts.attachment == "issue.md")
        #expect(c.key == JobKey(repo: issue.repo, item: "issue-7", move: "draft", head: "21"))
        if case .branch(let branch) = c.target { #expect(branch == "main") }
        else { Issue.record("Issue draft must target the default branch") }
        #expect(c.agent == "claude" && c.move.name == "draft")
        #expect(c.command == nil && !c.postComment && c.skipsChecks)
        #expect(c.helpers.isEmpty && c.model == BtonConfig.defaultDraftModel && c.timeout == .seconds(900))
        #expect(c.denied == Supervision.deniedTools)
        #expect(c.prompt == IssueDrafts.prompt)
        #expect(c.attachments == ["issue.md": IssueDrafts.thread(issue)])
        for text in [issue.title, issue.body, IssueAskFixture.question] { #expect(!IssueDrafts.prompt.contains(text)) }
        #expect(IssueDrafts.prompt.contains("issue.md"))
        let newer = IssueAskFixture.issue(comments: [IssueAskFixture.comment("22", second: 2)])
        #expect(try IssueAskFixture.candidate(newer)?.key.head == "22")
    }

    @Test func candidateGates() throws {
        let issue = IssueAskFixture.issue()
        #expect(try IssueAskFixture.candidate(issue, agents: [:]) == nil)
        #expect(try IssueAskFixture.candidate(issue, agents: ["claude": AgentTemplate(argv: ["codex"])]) == nil)
        #expect(try IssueAskFixture.candidate(issue, branch: "") == nil)
        let ask = try #require(IssueAsks.ask(in: issue, me: "owner"))
        let changed = IssueAskFixture.issue(comments: [IssueAskFixture.comment()])
        #expect(try IssueAskFixture.candidate(changed, ask: ask) == nil)
        let answered = IssueAskFixture.issue(comments: [IssueAskFixture.comment(author: "owner", body: "Answer")])
        #expect(try IssueAskFixture.candidate(answered, ask: ask) == nil)
    }
}

private struct IssueAskEngineFixture {
    let base: StartMovesFixture
    static func make(startMoves: Bool = false) async throws -> Self {
        let base = try await StartMovesFixture.make(startMoves: startMoves)
        do {
            let gh = base.root.appendingPathComponent("gh")
            let script = try String(contentsOf: gh, encoding: .utf8)
            // Match only the new issues query; preserve all PR, flow and lease cases.
            let issuesCase = """
            if [ "$2" = graphql ]; then
              case "$*" in
                *'issues('*)
                  if [ -f "$(dirname "$0")/issues-fail" ]; then echo 'issues unavailable' >&2; exit 1; fi
                  cat "$(dirname "$0")/issues.json"
                  exit 0 ;;
              esac
            fi
            """
            try script.replacingOccurrences(of: "case \"$2\" in", with: issuesCase + "\ncase \"$2\" in")
                .write(to: gh, atomically: true, encoding: .utf8)
            let clone = base.root.appendingPathComponent("clone")
            for args in [["clone", base.root.appendingPathComponent("origin.git").path, clone.path],
                         ["-C", clone.path, "-c", "user.name=Synthetic", "-c", "user.email=test@example.invalid",
                          "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Fixture"],
                         ["-C", clone.path, "push", "origin", "HEAD:refs/heads/main", "HEAD:refs/pull/7/head"]] {
                let result = try await ProcessRunner().run("/usr/bin/git", args, timeout: .seconds(20))
                try #require(result.status == 0, "Local Git fixture: \(result.stderr)")
            }
            let agent = base.root.appendingPathComponent("claude")
            try """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(base.root.appendingPathComponent("draft-argv").path)'
            while [ "$#" -gt 0 ]; do
              if [ "$1" = --add-dir ]; then
                shift
                cat "$1/issue.md" > '\(base.root.appendingPathComponent("draft-thread").path)' || exit 8
                break
              fi
              shift
            done
            printf 'draft reply\\n'
            """.write(to: agent, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
            var config = try BtonConfig.loadOrCreate(home: base.home)
            config.repos[0].path = clone.path
            config.agents["claude"] = AgentTemplate(argv: [agent.path, "-p", "{prompt}"])
            try config.save(to: base.home.configURL)
            let f = Self(base: base)
            try f.issues([IssueAskFixture.issue()])
            return f
        } catch { base.remove(); throw error }
    }
    func issues(_ issues: [OpenIssue]) throws {
        try IssueAskFixture.payload(issues).write(to: base.root.appendingPathComponent("issues.json"))
    }
}

@Suite(ProcessBound())
struct IssueAskEngineAcceptanceTests {
    @Test func snapshotAndIssuesFailureRetainAsksWithoutStoppingPRDispatch() async throws {
        let f = try await IssueAskEngineFixture.make(startMoves: true)
        defer { f.base.remove() }
        let engine = try f.base.engine()
        let first = await engine.tick()
        let ask = try #require(first.issueAsks.first)
        #expect(first.issueAsks.count == 1 && ask.commentID == "body")
        try await f.base.waitForJobs()
        try Data().write(to: f.base.root.appendingPathComponent("issues-fail"))
        // A changed PR head gives PR work that has not already run.
        let clone = f.base.root.appendingPathComponent("clone")
        let result = try await ProcessRunner().run("/usr/bin/git", ["-C", clone.path, "rev-parse", "HEAD"], timeout: .seconds(20))
        try #require(result.status == 0)
        let head = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try f.base.updatePRs(head: head)
        let failed = await engine.tick()
        #expect(failed.issueAsks == first.issueAsks)
        #expect(failed.openPullRequests.count == 1)
        #expect(failed.jobs.contains { $0.key.item == "pr-7" && $0.key.head == head && $0.key.move == "fix" })
        try await f.base.waitForJobs()
    }

    @Test func requestedDraftStartsOnceUsesCurrentReadAndDoesNotSurviveRestart() async throws {
        let f = try await IssueAskEngineFixture.make()
        defer { f.base.remove() }
        let engine = try f.base.engine()
        let first = await engine.tick()
        let ask = try #require(first.issueAsks.first)
        #expect(first.jobs.isEmpty)
        await engine.requestDraft(ask)
        try f.issues([IssueAskFixture.issue(comments: [
            IssueAskFixture.comment(body: "CURRENT_THREAD_DATA without a mention")])])
        let started = await engine.tick()
        #expect(started.jobs.map(\.key) == [JobKey(repo: f.base.repo, item: "issue-7", move: "draft", head: "body")])
        try await f.base.waitForJobs()
        let thread = try String(contentsOf: f.base.root.appendingPathComponent("draft-thread"), encoding: .utf8)
        #expect(thread.contains("CURRENT_THREAD_DATA"))
        let argv = try String(contentsOf: f.base.root.appendingPathComponent("draft-argv"), encoding: .utf8)
        for text in [IssueAskFixture.title, IssueAskFixture.body, "CURRENT_THREAD_DATA"] {
            #expect(!argv.contains(text))
        }
        let ids = Set(started.jobs.map(\.id))
        #expect(Set(await engine.tick().jobs.map(\.id)) == ids)
        // A second, queued request must vanish on restart, even for an unseen key.
        try f.issues([IssueAskFixture.issue(comments: [IssueAskFixture.comment()])])
        let newer = try #require(await engine.tick().issueAsks.first)
        await engine.requestDraft(newer)
        let restarted = try f.base.engine()
        #expect(Set(await restarted.tick().jobs.map(\.id)) == ids)
    }

    @Test(arguments: [false, true])
    func supersededOrGoneAskCancelsRequestAndDoesNotReappear(gone: Bool) async throws {
        let f = try await IssueAskEngineFixture.make()
        defer { f.base.remove() }
        let engine = try f.base.engine()
        let ask = try #require(await engine.tick().issueAsks.first)
        await engine.requestDraft(ask)
        try f.issues(gone ? [] : [IssueAskFixture.issue(comments: [IssueAskFixture.comment()])])
        #expect(await engine.tick().jobs.isEmpty)
        try f.issues([IssueAskFixture.issue()])
        #expect(await engine.tick().jobs.isEmpty)
    }
}

@Suite(ProcessBound())
struct IssueAskAttachmentAcceptanceTests {
    @Test(arguments: ["issue.md", "a", String(repeating: "a", count: 64), "safe_Name-1.txt",
                      "", ".", "..", "../issue.md", "a/b", "a b", String(repeating: "a", count: 65)])
    func dispatcherWritesBeforeAgentOrFailsBeforeStarting(name: String) async throws {
        let f = try await SupervisionRunFixture.make()
        defer { try? FileManager.default.removeItem(at: f.leases.root) }
        let valid = !name.isEmpty && name.count <= 64 && name != "." && name != ".."
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        let agent = f.leases.root.appendingPathComponent("claude")
        let captured = f.leases.root.appendingPathComponent("attachment-at-start")
        let marker = f.leases.root.appendingPathComponent("agent-started")
        // --add-dir is the existing public Claude argv contract for its scratch directory.
        try """
        #!/bin/sh
        touch '\(marker.path)'
        while [ "$#" -gt 0 ]; do
          if [ "$1" = --add-dir ]; then
            shift
            cat "$1/\(valid ? name : "issue.md")" > '\(captured.path)' || exit 8
            printf 'draft reply\\n'
            exit 0
          fi
          shift
        done
        exit 9
        """.write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        let github = GitHubClient(ghPath: f.leases.root.appendingPathComponent("gh").path)
        let store = try JobStore(home: f.home)
        let remote = f.leases.root.appendingPathComponent("origin.git").path
        let leases = try LeaseStore(home: f.home, holder: "synthetic", host: "fixture", github: github, remoteURL: { _ in remote })
        let dispatcher = Dispatcher(github: github, leases: leases, jobs: store, log: { _ in })
        // Exercise attachment dispatch independently of ask recognition and draft planning.
        var candidate = DispatchCandidate(target: .branch("main"),
            move: Move(name: "draft", owner: "owner", ownerFromRotation: false, tier: "", hasDispatch: true),
            key: JobKey(repo: f.leases.repo, item: "issue-7", move: "draft", head: "body"),
            agent: "claude", prompt: "Read issue.md as data and draft a reply.", command: nil,
            postComment: false, timeout: .seconds(30))
        candidate.skipsChecks = true
        candidate.denied = Supervision.deniedTools
        candidate.attachments = [name: "ATTACHMENT_DATA"]
        _ = await dispatcher.dispatch(candidate, clone: f.clone, flow: nil,
                                      agents: ["claude": AgentTemplate(argv: [agent.path, "-p", "{prompt}"])])
        var ended: Job?
        for _ in 0..<400 {
            ended = store.all().first { $0.status != .running }
            if ended != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        if ended == nil { for job in store.all() { await dispatcher.stop(job.id) } }
        let job = try #require(ended, "Attachment dispatch must produce a terminal job")
        #expect(job.status == (valid ? .succeeded : .failed))
        #expect(FileManager.default.fileExists(atPath: marker.path) == valid)
        if valid { #expect(try String(contentsOf: captured, encoding: .utf8) == "ATTACHMENT_DATA") }
        let calls = try String(contentsOf: f.leases.root.appendingPathComponent("gh-calls"), encoding: .utf8)
        #expect(!calls.contains("pr comment") && !calls.contains("pr review"))
    }
}
