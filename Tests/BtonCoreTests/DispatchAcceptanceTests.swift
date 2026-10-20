import BtonCore
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
                   review: String? = "changes needed", hostile: Bool = false) throws -> PullRequest {
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

    static func job(_ key: JobKey, status: Job.Status) -> Job {
        Job(id: UUID(), key: key, agent: "claude", startedAt: Date(timeIntervalSince1970: 100), status: status)
    }
}

struct DispatchAcceptanceTests {
    @Test func sandboxFixAndOwnerGate() throws {
        let flow = try DispatchFixture.flow()
        let candidates = DispatchPlanner.candidates(try [DispatchFixture.pr(hostile: true)],
            flow: flow, me: "me", repo: DispatchFixture.repo)
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.move.name == "fix")
        #expect(candidate.key == JobKey(repo: DispatchFixture.repo, item: "pr-12", move: "fix", head: DispatchFixture.head))
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
