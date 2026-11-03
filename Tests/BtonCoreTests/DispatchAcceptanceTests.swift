@testable import BtonCore
import Foundation
import Testing

private enum DispatchFixture {
    static let head = "abcdef12" + String(repeating: "a", count: 32)
    static let repo = "synthetic/project"
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func flow(_ name: String = "sandbox") throws -> Flow {
        try JSONDecoder().decode(Flow.self, from: Data(contentsOf:
            root.appendingPathComponent("examples/\(name).flow.json")))
    }

    // Synthetic GraphQL envelope, independent of FlowAcceptanceTests' private helpers.
    static func pr(number: Int = 12, author: String = "me", base: String = "main",
                   review: String? = "changes needed", hostile: Bool = false, head: String = head) throws -> PullRequest {
        let comments: [[String: Any]] = review.map { verdict in
            [["author": ["login": "reviewer"], "authorAssociation": "MEMBER", "body": "## Review: \(verdict) (head abcdef12)",
              "createdAt": "2026-10-19T12:00:00Z"]]
        } ?? []
        let node: [String: Any] = [
            "number": number, "title": hostile ? "TITLE_INJECTION; touch /tmp/no" : "Synthetic PR",
            "url": "https://github.com/synthetic/project/pull/\(number)", "isDraft": false,
            "headRefOid": head, "headRefName": hostile ? "BRANCH_INJECTION" : "feat/synthetic",
            "baseRefName": base, "body": "**Tier:** feature\n" + (hostile ? "BODY_INJECTION" : ""),
            "updatedAt": "2026-10-19T11:00:00Z", "authorAssociation": "OWNER",
            "author": ["login": author], "labels": ["nodes": []],
            "assignees": ["nodes": [["login": "me"]]], "comments": ["nodes": comments]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["data": [
            "viewer": ["login": "me"], "repository": ["defaultBranchRef": ["name": "main"],
            "pullRequests": ["nodes": [node]]]]])
        return try #require(GitHubClient.decodeOpenPullRequests(data, repo: repo).pullRequests.first)
    }

    static func candidates() throws -> [DispatchCandidate] {
        DispatchPlanner.candidates(try [pr(), pr(number: 13)], flow: try flow(), me: "me", repo: repo)
    }

    static func job(_ key: JobKey, status: Job.Status, detail: String? = nil, retry: Bool? = nil) -> Job {
        Job(id: UUID(), key: key, agent: "claude", startedAt: Date(timeIntervalSince1970: 100),
            status: status, detail: detail, retry: retry)
    }

    static func review(head: String = head, round: String = "2") throws -> DispatchCandidate {
        DispatchCandidate(target: .pullRequest(try pr(author: "other", review: nil, head: head)),
            move: Move(name: "review", owner: "me", ownerFromRotation: false, tier: "feature", hasDispatch: true),
            key: JobKey(repo: repo, item: "pr-12", move: "review", head: head, round: round),
            agent: "claude", prompt: "Review the PR", command: nil, postComment: true, timeout: .seconds(300))
    }
}

@Suite(ProcessBound())
struct DispatchAcceptanceTests {
    // CostAcceptanceTests prices standalone session files; this file's fixture only plans
    // candidates. Neither it nor IntakeDispatcherAcceptanceTests can price a running fake
    // session, so Part A3 is covered at JobBudget and candidate boundaries, not the run loop.
    @Test(arguments: [("1.26", "1.25", "1.26", "1.25"), ("2", "1", "2.00", "1.00")])
    func aJobOverItsBudgetExplainsTheApproximateSessionLogCost(cost: String, cap: String, spent: String, limit: String) {
        #expect(JobBudget.overrun(cost: Decimal(string: cost), cap: Decimal(string: cap))
            == "budget: $\(spent) spent of the $\(limit) cap (read from the session logs, so approximate)")
    }

    @Test(arguments: [Decimal(string: "1.24")!, Decimal(string: "1.25")!])
    func aJobUnderOrExactlyAtItsBudgetMayContinue(cost: Decimal) {
        #expect(JobBudget.overrun(cost: cost, cap: Decimal(string: "1.25")) == nil)
    }

    @Test(arguments: [(Optional<Decimal>.none, Optional(Decimal(1))),
                      (Optional(Decimal(100)), Optional<Decimal>.none),
                      (Optional<Decimal>.none, Optional<Decimal>.none)])
    func anUnknownCostOrAbsentCapNeverStopsAJob(cost: Decimal?, cap: Decimal?) {
        #expect(JobBudget.overrun(cost: cost, cap: cap) == nil)
    }

    @Test(arguments: ["agent", "command"], [false, true])
    func prCandidatesCarryTheFlowCostCap(kind: String, capped: Bool) throws {
        let dispatch: [String: Any] = kind == "agent"
            ? ["agent": "claude", "prompt": "Fix #{number}"] : ["command": ["/usr/bin/true"]]
        let flow = try #require(Flow.load(FlowFixture.data(overrides: [
            "caps": capped ? ["costPerJob": 1.25] : [:],
            "moves": [["move": "fix", "when": ["no_review_or_response_newer"], "who": "author"]],
            "dispatch": ["fix": dispatch]
        ])).flow)
        let pr = try DispatchFixture.pr(base: flow.base, review: nil)
        let candidate = try #require(DispatchPlanner.candidates([pr], flow: flow, me: "me", repo: pr.repo).first)
        #expect(candidate.costCap == (capped ? Decimal(string: "1.25") : nil))
    }

    @Test(arguments: ["check git merge-tree exited 1", "posting the check failure failed: offline"], [false, true])
    func retryFlagDoesNotBypassFailedCheckWithoutAnOwnerPress(detail: String, pressed: Bool) throws {
        let candidate = try DispatchFixture.review()
        let old = JobKey(repo: candidate.key.repo, item: candidate.key.item, move: candidate.key.move,
                         head: candidate.key.head, round: "1")
        let jobs = [DispatchFixture.job(old, status: .failed, detail: detail, retry: true)]
        #expect(DispatchPlanner.checkFailedOnHead(candidate.key, jobs: jobs))
        let selected = DispatchPlanner.select([candidate], jobs: jobs, maxAgents: 1,
            agents: ["claude": AgentTemplate(argv: ["claude"])],
            first: pressed ? ["\(candidate.key.repo)#\(candidate.key.item)"] : [])
        #expect(selected.map(\.key) == (pressed ? [candidate.key] : []))
    }

    @Test(arguments: ["check git merge-tree exited 1", "posting the check failure failed: offline"])
    func failedCheckOnSameHeadBlocksTheNextRound(detail: String) throws {
        let candidate = try DispatchFixture.review()
        let old = JobKey(repo: candidate.key.repo, item: candidate.key.item, move: candidate.key.move,
                         head: candidate.key.head, round: "1")
        let jobs = [DispatchFixture.job(old, status: .failed, detail: detail)]
        #expect(DispatchPlanner.checkFailedOnHead(candidate.key, jobs: jobs))
        #expect(DispatchPlanner.select([candidate], jobs: jobs, maxAgents: 1,
                                      agents: ["claude": AgentTemplate(argv: ["claude"])]).isEmpty)
    }

    @Test func pressedCandidateCanRetryAFailedCheckOnTheSameHead() throws {
        let candidate = try DispatchFixture.review()
        let old = JobKey(repo: candidate.key.repo, item: candidate.key.item, move: candidate.key.move,
                         head: candidate.key.head, round: "1")
        let selected = DispatchPlanner.select([candidate],
            jobs: [DispatchFixture.job(old, status: .failed, detail: "check git merge-tree exited 1")],
            maxAgents: 1, agents: ["claude": AgentTemplate(argv: ["claude"])],
            first: ["\(candidate.key.repo)#\(candidate.key.item)"])
        #expect(selected.map(\.key) == [candidate.key])
    }

    @Test func changedHeadCanRunAfterAnEarlierHeadFailedItsCheck() throws {
        let candidate = try DispatchFixture.review(head: String(repeating: "b", count: 40))
        let old = JobKey(repo: candidate.key.repo, item: candidate.key.item, move: candidate.key.move,
                         head: DispatchFixture.head, round: "1")
        let jobs = [DispatchFixture.job(old, status: .failed, detail: "check git merge-tree exited 1")]
        #expect(!DispatchPlanner.checkFailedOnHead(candidate.key, jobs: jobs))
        #expect(DispatchPlanner.select([candidate], jobs: jobs, maxAgents: 1,
                                      agents: ["claude": AgentTemplate(argv: ["claude"])]).map(\.key) == [candidate.key])
    }

    @Test func agentFailureDoesNotBlockAnotherRoundOnTheSameHead() throws {
        let candidate = try DispatchFixture.review()
        let old = JobKey(repo: candidate.key.repo, item: candidate.key.item, move: candidate.key.move,
                         head: candidate.key.head, round: "1")
        let jobs = [DispatchFixture.job(old, status: .failed, detail: "agent exited 1")]
        #expect(!DispatchPlanner.checkFailedOnHead(candidate.key, jobs: jobs))
        #expect(DispatchPlanner.select([candidate], jobs: jobs, maxAgents: 1,
                                      agents: ["claude": AgentTemplate(argv: ["claude"])]).map(\.key) == [candidate.key])
    }

    @Test func failedCheckMatchesOnlyTheSameRepoItemAndMove() throws {
        let key = try DispatchFixture.review().key
        let others = [JobKey(repo: "other/project", item: key.item, move: key.move, head: key.head),
                      JobKey(repo: key.repo, item: "pr-99", move: key.move, head: key.head),
                      JobKey(repo: key.repo, item: key.item, move: "fix", head: key.head)]
        for other in others {
            #expect(!DispatchPlanner.checkFailedOnHead(key,
                jobs: [DispatchFixture.job(other, status: .failed, detail: "check git merge-tree exited 1")]))
        }
    }

    @Test func sandboxFixAndOwnerGate() throws {
        let flow = try DispatchFixture.flow()
        let candidates = DispatchPlanner.candidates(try [DispatchFixture.pr(hostile: true)],
            flow: flow, me: "me", repo: DispatchFixture.repo)
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.move.name == "fix")
        #expect(candidate.key == DispatchPlanner.key(for: try DispatchFixture.pr(hostile: true), move: "fix", flow: flow, me: "me", repo: DispatchFixture.repo))
        #expect(candidate.agent == "claude")
        #expect(candidate.prompt == "Bton e2e: PR #12 of synthetic/project at head \(DispatchFixture.head). Reply with the single word done.")
        #expect(candidate.command == nil)
        #expect(!candidate.postComment)
        #expect(candidate.timeout == .seconds(300))
        #expect(DispatchPlanner.candidates(try [DispatchFixture.pr(author: "other")],
            flow: flow, me: "me", repo: DispatchFixture.repo).isEmpty)
    }

    @Test func teamReviewAndMerge() throws {
        let flow = try DispatchFixture.flow("team")
        let reviews = DispatchPlanner.candidates(try [DispatchFixture.pr(author: "other", base: "develop", review: nil)],
            flow: flow, me: "me", repo: DispatchFixture.repo)
        let review = try #require(reviews.first)
        #expect(reviews.count == 1)
        #expect(review.move.name == "review")
        #expect(review.agent == "claude")
        #expect(review.postComment)
        #expect(review.timeout == .seconds(3600))
        let merges = DispatchPlanner.candidates(try [DispatchFixture.pr(base: "develop", review: "approve")],
            flow: flow, me: "me", repo: DispatchFixture.repo)
        let merge = try #require(merges.first)
        #expect(merges.count == 1)
        #expect(merge.move.name == "merge")
        #expect(merge.agent == nil)
        #expect(merge.command == ["bash", "scripts/wt", "merge", "12"])
        #expect(DispatchPlanner.select(merges, jobs: [], maxAgents: 1, agents: [:]).count == 1)
    }

    @Test(arguments: [Job.Status.running, .succeeded, .failed, .cancelled])
    func existingKeyNeverRunsAgain(status: Job.Status) throws {
        let candidates = try DispatchFixture.candidates()
        let first = try #require(candidates.first)
        let agents = ["claude": AgentTemplate(argv: ["claude", "{prompt}"])]
        let selected = DispatchPlanner.select([first], jobs: [DispatchFixture.job(first.key, status: status)], maxAgents: 5, agents: agents)
        #expect(selected.isEmpty)
    }

    @Test func headChangesSlotsAndMissingAgent() throws {
        let candidates = try DispatchFixture.candidates()
        let first = try #require(candidates.first)
        let agents = ["claude": AgentTemplate(argv: ["claude", "{prompt}"])]
        let oldHead = JobKey(repo: DispatchFixture.repo, item: "pr-12", move: "fix", head: "old-head")
        #expect(DispatchPlanner.select([first], jobs: [DispatchFixture.job(oldHead, status: .failed)], maxAgents: 1, agents: agents).count == 1)
        let other = JobKey(repo: DispatchFixture.repo, item: "pr-99", move: "review", head: "other-head")
        #expect(DispatchPlanner.select(candidates, jobs: [DispatchFixture.job(other, status: .running)], maxAgents: 1, agents: agents).isEmpty)
        let sameItem = JobKey(repo: DispatchFixture.repo, item: "pr-12", move: "review", head: "other-head")
        #expect(DispatchPlanner.select([first], jobs: [DispatchFixture.job(sameItem, status: .running)], maxAgents: 5, agents: agents).isEmpty)
        #expect(DispatchPlanner.select(candidates, jobs: [], maxAgents: 1, agents: agents).map(\.key) == [first.key])
        #expect(DispatchPlanner.select(candidates, jobs: [], maxAgents: 2, agents: [:]).isEmpty)
        #expect(DispatchPlanner.select(candidates, jobs: [], maxAgents: 0, agents: agents).isEmpty)
    }

    @Test func safePlaceholderAndArgvExpansion() {
        #expect(DispatchPlanner.fill("{repo} {number} {head} {base} {issue} {unknown} {title} {body} {branch}",
            repo: "synthetic/project", number: 12, head: DispatchFixture.head, base: "main", issue: 7)
            == "synthetic/project 12 \(DispatchFixture.head) main 7 {unknown} {title} {body} {branch}")
        let session = UUID(uuidString: "ABCDEF12-1234-1234-1234-123456789ABC")!
        let prompt = "spaces 'quotes' \"double\"; command\nnext line"
        #expect(DispatchPlanner.argv(["agent", "--session={session}", "{prompt}"], prompt: prompt, session: session)
            == ["agent", "--session=abcdef12-1234-1234-1234-123456789abc", prompt])
    }

    @Test(arguments: [
        ("## Review: approve (head ABCDEF12)\nFindings\n  ", true),
        ("## Review: changes (head 1234567)", false),
        ("## Review: approve", false), ("No heading (head abcdef12)", false),
        ("\n## Review: approve (head abcdef12)", false), ("", false)
    ])
    func finalReviewMessage(text: String, valid: Bool) {
        let result = DispatchPlanner.reviewComment(fromFinalMessage: text, headings: ["## Review:"], head: DispatchFixture.head)
        #expect(result == (valid ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil))
    }

    @Test func leaseKeyJSONCompatibility() throws {
        let record = LeaseRecord(holder: "synthetic", host: "fixture", job: UUID(),
            expires: Date(timeIntervalSince1970: 100), released: false, key: "synthetic-key")
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(LeaseRecord.self, from: data) == record)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "key")
        let decoded = try JSONDecoder().decode(LeaseRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.key == nil)
        #expect(decoded.job == record.job)
    }

    @Test func jobStorePersistsSkipsGarbageAndUpdates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobStore(home: BtonHome(environment: ["BTON_HOME": directory.path]))
        let key = JobKey(repo: DispatchFixture.repo, item: "pr-12", move: "fix", head: DispatchFixture.head)
        let initial = DispatchFixture.job(key, status: .running)
        try store.save(initial)
        try Data("not JSON".utf8).write(to: directory.appendingPathComponent("jobs/garbage.json"))
        #expect(try JobStore(home: BtonHome(environment: ["BTON_HOME": directory.path])).all() == [initial])
        let updated = Job(id: initial.id, key: key, agent: "claude", pid: 1234,
            worktree: directory.appendingPathComponent("worktree").path, startedAt: initial.startedAt,
            endedAt: Date(timeIntervalSince1970: 200), status: .succeeded, detail: "done",
            usage: ["synthetic-model": TokenUsage(input: 10, cacheRead: 20, cacheWrite: 30, output: 40)], cost: Decimal(string: "1.23"))
        try store.save(updated)
        #expect(try JobStore(home: BtonHome(environment: ["BTON_HOME": directory.path])).all() == [updated])
        #expect(store.logURL(initial.id).deletingLastPathComponent() == directory.appendingPathComponent("jobs"))
        #expect(store.outputURL(initial.id).deletingLastPathComponent() == directory.appendingPathComponent("jobs"))
    }
}
