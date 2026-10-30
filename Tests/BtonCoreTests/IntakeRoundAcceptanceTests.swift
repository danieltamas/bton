import Foundation
import Testing
@testable import BtonCore

@Suite struct IntakeRoundAcceptanceTests {
    typealias F = IntakeAcceptanceFixture

    private func comment(_ time: Double, author: String? = "outsider") -> IssueComment {
        IssueComment(id: String(time), author: author, authorAssociation: "NONE", body: "Decision",
                     createdAt: Date(timeIntervalSince1970: time), url: nil)
    }

    private func issue(_ comments: [IssueComment]) -> OpenIssue {
        let seed = F.issue()
        return OpenIssue(repo: seed.repo, number: seed.number, title: seed.title, url: seed.url,
                         createdAt: seed.createdAt, author: seed.author, authorAssociation: seed.authorAssociation,
                         body: seed.body, comments: comments, labels: seed.labels, assignees: seed.assignees)
    }

    @Test func roundIsEmptyWithoutCommentsAndUsesNewestRegardlessOfOrderOrAuthor() {
        #expect(IssueIntake.round(of: issue([])) == "")
        let shuffled = issue([comment(2000.9, author: nil), comment(1000), comment(1500)])
        #expect(IssueIntake.round(of: shuffled) == "2000")
    }

    @Test func keyCarriesRoundAndDistinguishesOtherwiseIdenticalJobs() {
        let first = IssueIntake.key(repo: F.repo, number: 7, round: "1000")
        #expect(first == JobKey(repo: F.repo, item: "issue-7", move: IssueIntake.move, head: "", round: "1000"))
        #expect(first.round == "1000")
        #expect(first != IssueIntake.key(repo: F.repo, number: 7, round: "2000"))
    }

    private func checkNewRound(after status: Job.Status) throws {
        let earlier = issue([comment(1000.9)])
        let job = Job(id: UUID(),
                      key: JobKey(repo: F.repo, item: "issue-7", move: "implement", head: "", round: "1000"),
                      agent: "claude", startedAt: Date(timeIntervalSince1970: 1100), status: status, retry: false)
        #expect(try F.candidate([earlier], jobs: [job]) == nil)
        let returned = issue(earlier.comments + [comment(2000.9, author: "Dani")])
        let candidate = try #require(try F.candidate([returned], jobs: [job]))
        #expect(try F.plan(candidate).issue == earlier.number)
        #expect(candidate.key.round == "2000")
        #expect(candidate.key == JobKey(repo: F.repo, item: "issue-7", move: "implement", head: "", round: "2000"))
        #expect(try !F.plan(candidate).resumes)
    }

    @Test func succeededRoundStaysUsedUntilANewerComment() throws {
        try checkNewRound(after: .succeeded)
    }

    @Test func failedRoundWithoutRetryStaysUsedUntilANewerComment() throws {
        try checkNewRound(after: .failed)
    }

    @Test func readyCarriesItsOpenIssuesRound() throws {
        let open = issue([comment(2000.9), comment(1000)])
        let ready = try #require(IssueIntake.ready([open], priority: ["priority:high"], held: []).first)
        #expect(ready.round == "2000")
        #expect(ready.round == IssueIntake.round(of: open))
        #expect(IssueIntake.ready([issue([])]).first?.round == "")
    }
}

// Same real temporary clone and fake command boundary as IntakeDispatcherAcceptanceTests;
// call prepareIssue directly so no agent, lease acquisition, or PR outcome masks preparation.
@Suite(ProcessBound()) struct IntakeRoundWorktreeAcceptanceTests {
    @Test func cleanEmptyEarlierWorktreeIsReusedAfterClaim() async throws {
        try await checkWorktree("clean")
    }

    @Test func dirtyEarlierWorktreeIsRefused() async throws {
        try await checkWorktree("dirty")
    }

    @Test func earlierWorktreeWithCommitBeyondBaseIsRefused() async throws {
        try await checkWorktree("ahead")
    }

    private func checkWorktree(_ scenario: String) async throws {
        let f = try await SupervisionRunFixture.make()
        defer { try? FileManager.default.removeItem(at: f.leases.root) }
        let fm = FileManager.default
        let root = f.leases.root
        let tree = f.clone.appendingPathComponent(".worktrees/issue-7", isDirectory: true).standardizedFileURL
        let calls = root.appendingPathComponent("round-calls")
        func git(_ args: [String], in directory: URL) async throws -> String {
            let result = try await ProcessRunner().run("/usr/bin/git", args, in: directory, timeout: .seconds(30))
            try #require(result.status == 0, "Git fixture failed: \(result.stderr)")
            return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Explicit remote ref: the safety test must compare against origin/<plan.base>.
        _ = try await git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: f.clone)
        _ = try await git(["worktree", "add", "-b", "issue-7", tree.path, "main"], in: f.clone)
        let baseHead = try await git(["rev-parse", "HEAD"], in: tree)
        if scenario == "dirty" {
            try Data("preserve me".utf8).write(to: tree.appendingPathComponent("owner-work"))
        } else if scenario == "ahead" {
            _ = try await git(["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                               "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Owner work"], in: tree)
        }
        let headBefore = try await git(["rev-parse", "HEAD"], in: tree)
        let statusBefore = try await git(["status", "--porcelain"], in: tree)
        #expect(try await git(["rev-list", "--count", "origin/main..HEAD"], in: tree) == (scenario == "ahead" ? "1" : "0"))
        #expect((scenario == "dirty") == !statusBefore.isEmpty)
        let claim = root.appendingPathComponent("round-claim")
        let worktree = root.appendingPathComponent("round-worktree")
        for (script, name) in [(claim, "claim"), (worktree, "worktree")] {
            try """
            #!/bin/sh
            printf '\(name)\\n' >> '\(calls.path)'
            """.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        let terms = try #require(IssueIntake.terms(["no:assignee", "label:stage:ready"], repo: f.leases.repo))
        let plan = IntakePlan(issue: 7, base: "main", terms: terms, claim: [[claim.path]],
                              worktree: [worktree.path], worktreePath: ".worktrees/issue-7", resumes: false)
        let github = GitHubClient(ghPath: root.appendingPathComponent("gh").path)
        let store = try JobStore(home: f.home)
        let remote = root.appendingPathComponent("origin.git").path
        let leases = try LeaseStore(home: f.home, holder: "intake-round", host: "fixture", github: github, remoteURL: { _ in remote })
        let dispatcher = Dispatcher(github: github, leases: leases, jobs: store, log: { _ in })
        let job = Job(id: UUID(), key: JobKey(repo: f.leases.repo, item: "issue-7", move: "implement", head: "", round: "2000"),
                      agent: "claude", startedAt: .now, status: .running)
        try store.save(job)
        var prepared: URL?
        var refusal: String?
        do {
            prepared = try await dispatcher.prepareIssue(plan, clone: f.clone, job: job, environment: [:], timeout: .seconds(30))
        } catch {
            refusal = error.localizedDescription
        }
        let order = fm.fileExists(atPath: calls.path) ? try String(contentsOf: calls, encoding: .utf8) : ""
        if scenario == "clean" {
            #expect(refusal == nil)
            #expect(prepared == tree)
            #expect(order == "claim\n")
            let log = try String(contentsOf: store.logURL(job.id), encoding: .utf8)
            #expect(log.contains("reusing \(plan.worktreePath), left empty by an earlier run"))
            #expect(headBefore == baseHead)
        } else {
            #expect(prepared == nil)
            #expect(refusal?.contains("already exists; nothing was claimed or made over it") == true)
            #expect(order.isEmpty)
        }
        #expect(try await git(["rev-parse", "HEAD"], in: tree) == headBefore)
        #expect(try await git(["status", "--porcelain"], in: tree) == statusBefore)
        if scenario == "dirty" {
            #expect(try String(contentsOf: tree.appendingPathComponent("owner-work"), encoding: .utf8) == "preserve me")
        }
    }
}
