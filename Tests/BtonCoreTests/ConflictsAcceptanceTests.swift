@testable import BtonCore
import Foundation
import Testing

struct ConflictsAcceptanceTests {
    @Test func pullRequestsDefaultToNotConflictingAndAllowUpdatingConflictState() {
        var pr = ConflictsFixture.pr()
        #expect(!pr.conflicting)
        pr.conflicting = true
        #expect(pr.conflicting)
        pr.conflicting = false
        #expect(!pr.conflicting)
    }

    @Test func openPullRequestsQueryRequestsMergeability() {
        #expect(GitHubClient.openPullRequestsQuery.range(of: #"\bmergeable\b"#,
                                                       options: .regularExpression) != nil)
    }

    @Test func onlyConflictingMergeabilityDecodesAsConflicting() throws {
        let states: [String?] = ["CONFLICTING", "MERGEABLE", "UNKNOWN", nil]
        let nodes = states.enumerated().map { index, state in
            ConflictsFixture.node(number: index + 1, mergeable: state)
        }
        let data = try JSONSerialization.data(withJSONObject: ["data": [
            "viewer": ["login": "owner"], "repository": [
                "defaultBranchRef": ["name": "main"],
                "pullRequests": ["nodes": nodes,
                                 "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]
            ]
        ]])
        let page = try GitHubClient.decodeOpenPullRequests(data, repo: ConflictsFixture.key.repo)
        #expect(page.pullRequests.count == 4)
        for (index, _) in states.enumerated() {
            let pr = try #require(page.pullRequests.first { $0.number == index + 1 })
            #expect(pr.conflicting == (index == 0))
        }
    }

    @Test func conflictingApprovedHeadRoutesToAuthorsDispatchedResolveBeforeMerge() throws {
        let flow = try ConflictsFixture.flow()
        var pr = ConflictsFixture.pr(approved: true)
        pr.conflicting = true
        let resolve = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(resolve.name == "resolve")
        #expect(resolve.owner == pr.author)
        #expect(resolve.hasDispatch)

        pr.conflicting = false
        let merge = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(merge.name == "merge")
        #expect(merge.owner == pr.author)
    }

    @Test(arguments: [false, true])
    func conflictingPredicateDependsOnlyOnConflictFlag(conflicting: Bool) throws {
        var pr = ConflictsFixture.pr()
        pr.conflicting = conflicting
        let move = try #require(FlowEngine.move(for: pr, flow: ConflictsFixture.flow()))
        #expect(move.name == (conflicting ? "resolve" : "review"))
    }

    @Test(arguments: [false, true])
    func conflictingPredicateWithArgumentNeverMatches(conflicting: Bool) throws {
        var pr = ConflictsFixture.pr(approved: true)
        pr.conflicting = conflicting
        let flow = try ConflictsFixture.flow(predicate: "conflicting:x")
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "merge")
    }

    @Test func earlierDraftRuleStillWinsForConflictingDraft() throws {
        var pr = ConflictsFixture.pr(approved: true, draft: true)
        pr.conflicting = true
        let move = try #require(FlowEngine.move(for: pr,
                                               flow: ConflictsFixture.flow(draftFirst: true)))
        #expect(move.name == "finish")
        #expect(move.owner == pr.author)
        #expect(!move.hasDispatch)
    }

    @Test(arguments: [Job.Status.failed, .cancelled])
    func runNowPersistsRetryForFailedOrCancelledExactKey(status: Job.Status) async throws {
        let fixture = try ConflictsFixture()
        defer { fixture.remove() }
        let job = ConflictsFixture.job(status: status)
        try fixture.store().save(job)
        let engine = try fixture.engine()

        try await engine.runNow(job.key)

        var expected = job
        expected.retry = true
        let persisted = try fixture.store().all()
        #expect(persisted == [expected])
        #expect(DispatchPlanner.isRetry(job.key, jobs: persisted))
    }

    @Test func runNowLeavesSucceededJobUnchanged() async throws {
        let fixture = try ConflictsFixture()
        defer { fixture.remove() }
        let job = ConflictsFixture.job(status: .succeeded)
        try fixture.store().save(job)
        let engine = try fixture.engine()

        try await engine.runNow(job.key)

        let persisted = try fixture.store().all()
        #expect(persisted == [job])
        #expect(persisted.first?.retry != true)
        #expect(!DispatchPlanner.isRetry(job.key, jobs: persisted))
    }

    @Test func runNowWithoutStoredJobDoesNotCreateOne() async throws {
        let fixture = try ConflictsFixture()
        defer { fixture.remove() }
        let engine = try fixture.engine()
        let jobsURL = fixture.home.url.appendingPathComponent("jobs")
        let before = try FileManager.default.contentsOfDirectory(atPath: jobsURL.path)

        try await engine.runNow(ConflictsFixture.key)

        #expect(try fixture.store().all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: jobsURL.path) == before)
    }

    @Test func runNowDoesNotRetryFailedJobOnDifferentHead() async throws {
        let fixture = try ConflictsFixture()
        defer { fixture.remove() }
        let key = ConflictsFixture.key
        let otherHead = JobKey(repo: key.repo, item: key.item, move: key.move, head: "old-head")
        let job = ConflictsFixture.job(otherHead)
        try fixture.store().save(job)
        let engine = try fixture.engine()

        try await engine.runNow(key)

        let persisted = try fixture.store().all()
        #expect(persisted == [job])
        #expect(!DispatchPlanner.isRetry(key, jobs: persisted))
    }

    @Test func runNowRetriesOnlyLatestEligibleJobOnExactKey() async throws {
        let fixture = try ConflictsFixture()
        defer { fixture.remove() }
        let older = ConflictsFixture.job()
        let latest = ConflictsFixture.job(status: .cancelled, offset: 10)
        try fixture.store().save(older)
        try fixture.store().save(latest)
        let engine = try fixture.engine()

        try await engine.runNow(ConflictsFixture.key)

        let persisted = try fixture.store().all()
        var expected = latest
        expected.retry = true
        #expect(persisted.count == 2)
        #expect(persisted.first { $0.id == older.id } == older)
        #expect(persisted.first { $0.id == latest.id } == expected)
    }

    @Test func runNowPutsItemFirstAndDeduplicatesExistingRunNextPick() async throws {
        let fixture = try ConflictsFixture()
        defer { fixture.remove() }
        let engine = try fixture.engine()
        let key = ConflictsFixture.key
        await engine.runNext(repo: key.repo, item: key.item)
        await engine.runNext(repo: "other/project", item: "pr-8")

        try await engine.runNow(key)

        // A read-only tick with no watched repos exposes the queue without remote calls.
        let snapshot = await engine.tick(dispatching: false)
        #expect(snapshot.problem == nil)
        #expect(snapshot.next == ["synthetic/project#pr-7", "other/project#pr-8"])
    }
}

private struct ConflictsFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let head = "d67db2a8" + String(repeating: "a", count: 32)
    static let key = JobKey(repo: "synthetic/project", item: "pr-7", move: "merge", head: head)
    let root: URL
    let home: BtonHome

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-conflicts-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = BtonHome(environment: ["BTON_HOME": root.path])
        try BtonConfig(repos: [], pollSeconds: 60, maxAgents: 0, agents: [:], schedules: [])
            .save(to: home.configURL)
    }

    func store() throws -> JobStore { try JobStore(home: home) }

    func engine() throws -> Engine {
        try Engine(home: home, github: GitHubClient(ghPath: "/usr/bin/false"), log: { _ in })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func job(_ key: JobKey = ConflictsFixture.key, status: Job.Status = .failed,
                    offset: TimeInterval = 0) -> Job {
        Job(id: UUID(), key: key, agent: "synthetic", startedAt: now.addingTimeInterval(offset),
            endedAt: now.addingTimeInterval(offset + 1), status: status, detail: "Synthetic outcome")
    }

    static func pr(approved: Bool = false, draft: Bool = false) -> PullRequest {
        let comments: [PullRequestComment] = approved ? [
            .init(author: "reviewer", authorAssociation: "MEMBER",
                  body: "## Review: approve (head d67db2a8)", createdAt: now)
        ] : []
        return PullRequest(repo: key.repo, number: 7, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: head, headRef: "feature", baseRef: "main", body: "", isDraft: draft,
            labels: [], assignees: ["reviewer"], comments: comments, updatedAt: now)
    }

    static func node(number: Int, mergeable: String?) -> [String: Any] {
        var node: [String: Any] = [
            "number": number, "title": "Synthetic PR", "url": "https://example.invalid/pr/\(number)",
            "isDraft": false, "headRefOid": head, "headRefName": "feature", "baseRefName": "main",
            "body": "", "updatedAt": "2026-10-19T12:00:00Z", "authorAssociation": "OWNER",
            "author": ["login": "owner"], "labels": ["nodes": []],
            "assignees": ["nodes": []], "comments": ["nodes": []]
        ]
        if let mergeable { node["mergeable"] = mergeable }
        return node
    }

    static func flow(predicate: String = "conflicting", draftFirst: Bool = false) throws -> Flow {
        let draft = draftFirst ? #"{"move":"finish","when":["draft"],"who":"author"},"# : ""
        let json = """
        {"version":1,"base":"main",
         "tier":{"marker":"Tier:","values":["small"],"default":"small"},
         "reviews":{"small":[{"heading":"## Review:","notByAuthor":true}]},"fixed":"## Fixed:",
         "moves":[\(draft)
           {"move":"resolve","when":["\(predicate)"],"who":"author"},
           {"move":"review","when":["no_review_or_response_newer"],"who":"assignee"},
           {"move":"merge","when":["approved_current_head"],"who":"author"}],
         "dispatch":{"resolve":{"agent":"claude","prompt":"Resolve #{number}."}}}
        """
        return try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
    }
}
