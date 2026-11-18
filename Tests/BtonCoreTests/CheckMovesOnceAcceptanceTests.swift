import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct CheckMovesOnceAcceptanceTests {
    @Test func pr1083ApprovalDoesNotRepeatSuccessfulFixCIOnSameHead() throws {
        let flow = try CheckMovesOnceFixture.flow()
        var pr = CheckMovesOnceFixture.pr()
        let firstCandidates = DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo)
        #expect(firstCandidates.count == 1)
        let first = try #require(firstCandidates.first)
        #expect(first.key.round == "")
        let job = CheckMovesOnceFixture.job(key: first.key)

        pr.comments.append(CheckMovesOnceFixture.review("approve", at: CheckMovesOnceFixture.approvedAt))
        #expect(FlowEngine.round(of: pr, flow: flow, me: pr.author) == "1794859781")
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.key == job.key)
        #expect(DispatchPlanner.select(candidates, jobs: [job], maxAgents: 1,
                                      agents: CheckMovesOnceFixture.agents).isEmpty)
    }

    @Test(arguments: ["fix", "decide"])
    func reviewSensitiveMoveGetsNewKeyOnNewReview(move: String) throws {
        let flow = try CheckMovesOnceFixture.flow(move: move, when: ["latest_review_changes_or_blocked"])
        var pr = CheckMovesOnceFixture.pr()
        pr.comments = [CheckMovesOnceFixture.review("changes", at: CheckMovesOnceFixture.ranAt)]
        let first = try #require(DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo).first)
        let job = CheckMovesOnceFixture.job(key: first.key)
        pr.comments.append(CheckMovesOnceFixture.review("changes", at: CheckMovesOnceFixture.approvedAt))
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo)
        let next = try #require(candidates.first)
        #expect(next.key.head == first.key.head)
        #expect(next.key.round == "1794859781")
        #expect(next.key != first.key)
        #expect(DispatchPlanner.select(candidates, jobs: [job], maxAgents: 1,
                                      agents: CheckMovesOnceFixture.agents).map(\.key) == [next.key])
    }

    @Test func checkAndReviewPredicateStillGetsNewKeyOnNewReview() throws {
        let flow = try CheckMovesOnceFixture.flow(when: ["checks_red:gate", "latest_review_changes_or_blocked"])
        var pr = CheckMovesOnceFixture.pr()
        pr.comments = [CheckMovesOnceFixture.review("changes", at: CheckMovesOnceFixture.ranAt)]
        let first = try #require(DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo).first)
        pr.comments.append(CheckMovesOnceFixture.review("changes", at: CheckMovesOnceFixture.approvedAt))
        let next = try #require(DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo).first)
        #expect(next.key.head == first.key.head)
        #expect(next.key.round == "1794859781")
        #expect(next.key != first.key)
    }

    @Test func legacyRoundBlocksAutomaticStartButAllowsPressedStart() throws {
        let flow = try CheckMovesOnceFixture.flow()
        var pr = CheckMovesOnceFixture.pr()
        pr.comments = [CheckMovesOnceFixture.review("approve", at: CheckMovesOnceFixture.approvedAt)]
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo)
        let candidate = try #require(candidates.first)
        #expect(candidate.key.round == "")
        let legacyKey = JobKey(repo: pr.repo, item: "pr-1083", move: "fix-ci", head: pr.headSha,
                               round: "1794859781")
        let job = CheckMovesOnceFixture.job(key: legacyKey)
        #expect(DispatchPlanner.select(candidates, jobs: [job], maxAgents: 1,
                                      agents: CheckMovesOnceFixture.agents).isEmpty)
        #expect(DispatchPlanner.select(candidates, jobs: [job], maxAgents: 1,
                                      agents: CheckMovesOnceFixture.agents,
                                      first: ["\(pr.repo.lowercased())#pr-1083"]).map(\.key) == [candidate.key])
    }

    @Test func retriedLegacyRoundDoesNotBlockAutomaticStart() throws {
        let flow = try CheckMovesOnceFixture.flow()
        let pr = CheckMovesOnceFixture.pr()
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo)
        let candidate = try #require(candidates.first)
        let legacyKey = JobKey(repo: pr.repo, item: "pr-1083", move: "fix-ci", head: pr.headSha,
                               round: "1794859781")
        var job = CheckMovesOnceFixture.job(key: legacyKey)
        job.retry = true
        #expect(DispatchPlanner.select(candidates, jobs: [job], maxAgents: 1,
                                      agents: CheckMovesOnceFixture.agents).map(\.key) == [candidate.key])
    }

    @Test func redHeadNeverAskedAndNeverRunAsksForRerun() {
        #expect(CheckReruns.step(for: CheckMovesOnceFixture.key, failedChecks: ["gate"], pressed: false,
                                jobs: [], store: CheckRerunStore(), now: CheckMovesOnceFixture.ranAt) == .ask)
    }

    @Test func acceptedAskWaitsInsideSettleWindow() {
        #expect(CheckReruns.step(for: CheckMovesOnceFixture.key, failedChecks: ["gate"], pressed: false,
                                jobs: [], store: CheckMovesOnceFixture.store(asked: true),
                                now: CheckMovesOnceFixture.ranAt.addingTimeInterval(CheckReruns.settle - 1)) == .wait)
    }

    @Test func redHeadStartsAtAndAfterSettleDeadline() {
        for elapsed in [CheckReruns.settle, CheckReruns.settle + 1] {
            #expect(CheckReruns.step(for: CheckMovesOnceFixture.key, failedChecks: ["gate"], pressed: false,
                                    jobs: [], store: CheckMovesOnceFixture.store(asked: true),
                                    now: CheckMovesOnceFixture.ranAt.addingTimeInterval(elapsed)) == .start)
        }
    }

    @Test func refusedAskStartsWithoutWaitingOrAskingAgain() {
        for elapsed in [0.0, CheckReruns.settle + 1] {
            #expect(CheckReruns.step(for: CheckMovesOnceFixture.key, failedChecks: ["gate"], pressed: false,
                                    jobs: [], store: CheckMovesOnceFixture.store(asked: false),
                                    now: CheckMovesOnceFixture.ranAt.addingTimeInterval(elapsed)) == .start)
        }
    }

    @Test func pressedStartSkipsBothAskAndWait() {
        for store in [CheckRerunStore(), CheckMovesOnceFixture.store(asked: true)] {
            #expect(CheckReruns.step(for: CheckMovesOnceFixture.key, failedChecks: ["gate"], pressed: true,
                                    jobs: [], store: store, now: CheckMovesOnceFixture.ranAt) == .start)
        }
    }

    @Test(arguments: ["", "1794859781"])
    func moveAlreadyRunOnHeadStartsWithoutAsking(round: String) {
        let key = CheckMovesOnceFixture.key
        let oldKey = JobKey(repo: key.repo, item: key.item, move: key.move, head: key.head, round: round)
        #expect(CheckReruns.step(for: key, failedChecks: ["gate"], pressed: false,
                                jobs: [CheckMovesOnceFixture.job(key: oldKey)], store: CheckRerunStore(),
                                now: CheckMovesOnceFixture.ranAt) == .start)
    }

    @Test func unreadableStoreStartsWithoutAsking() {
        #expect(CheckReruns.step(for: CheckMovesOnceFixture.key, failedChecks: ["gate"], pressed: false,
                                jobs: [], store: nil, now: CheckMovesOnceFixture.ranAt) == .start)
    }

    @Test func noFailedChecksStartsWithoutAskingOrWaiting() {
        for store in [CheckRerunStore(), CheckMovesOnceFixture.store(asked: true)] {
            #expect(CheckReruns.step(for: CheckMovesOnceFixture.key, failedChecks: [], pressed: false,
                                    jobs: [], store: store, now: CheckMovesOnceFixture.ranAt) == .start)
        }
    }

    @Test func rerunStoreRoundTripsAndRetainsDecisionAfterReload() throws {
        let home = CheckMovesOnceFixture.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let taken = CheckMovesOnceFixture.store(asked: true).reruns[0]
        let refused = CheckRerun(repo: taken.repo, number: 1084, head: "other-head", at: taken.at, asked: false)
        let store = CheckRerunStore(reruns: [taken, refused])
        try store.save(home: home)
        let loaded = try #require(CheckRerunStore.load(home: home))
        #expect(loaded == store)
        #expect(CheckReruns.step(for: CheckMovesOnceFixture.key, failedChecks: ["gate"], pressed: false,
                                jobs: [], store: loaded, now: taken.at.addingTimeInterval(1)) == .wait)
        #expect(CheckReruns.step(for: CheckMovesOnceFixture.key, failedChecks: ["gate"], pressed: false,
                                jobs: [], store: loaded,
                                now: taken.at.addingTimeInterval(CheckReruns.settle + 1)) == .start)
    }

    @Test func missingRerunFileLoadsEmpty() throws {
        let home = CheckMovesOnceFixture.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        #expect(CheckRerunStore.load(home: home) == CheckRerunStore())
    }

    @Test func garbageRerunFileLoadsNil() throws {
        let home = CheckMovesOnceFixture.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        try Data("not valid JSON".utf8).write(to: home.url.appendingPathComponent("reruns.json"))
        #expect(CheckRerunStore.load(home: home) == nil)
    }

    @Test func pruningAndRestartDoNotRearmRerunOfSameUnrunHead() throws {
        // The first rerun went green without an agent. The PR remains open on that head;
        // a later failed workflow must not give it a second automatic rerun allowance.
        let home = CheckMovesOnceFixture.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let later = CheckMovesOnceFixture.ranAt.addingTimeInterval(31 * 86400)
        let store = CheckMovesOnceFixture.store(asked: true)
        try store.pruned(now: later).save(home: home)
        let reloaded = try #require(CheckRerunStore.load(home: home))
        #expect(CheckReruns.step(for: CheckMovesOnceFixture.key, failedChecks: ["gate"], pressed: false,
                                jobs: [], store: reloaded, now: later) == .start)
    }
}

private enum CheckMovesOnceFixture {
    static let head = "fa1fbb9d" + String(repeating: "a", count: 32)
    static let ranAt = Date(timeIntervalSince1970: 1_794_834_600)
    static let approvedAt = Date(timeIntervalSince1970: 1_794_859_781)
    static let key = JobKey(repo: "synthetic/kazu", item: "pr-1083", move: "fix-ci", head: head)
    static let agents = ["claude": AgentTemplate(argv: ["/usr/bin/true", "{prompt}"])]

    static func flow(move: String = "fix-ci", when predicates: [String] = ["checks_red:gate"]) throws -> Flow {
        let json: [String: Any] = [
            "version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:", "notByAuthor": true]]],
            "fixed": "## Fixed:",
            "decision": ["heading": "## Decision:", "move": "decide", "by": ["dani"]],
            "moves": [["move": move, "when": predicates, "who": "author"]],
            "dispatch": [move: ["agent": "claude", "prompt": "Handle PR {number}."]]
        ]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func review(_ verdict: String, at: Date) -> PullRequestComment {
        PullRequestComment(author: "vlad", authorAssociation: "MEMBER",
                           body: "## Review: \(verdict) (head \(head))\nSynthetic review.", createdAt: at)
    }

    static func pr() -> PullRequest {
        var pr = PullRequest(repo: key.repo, number: 1083, title: "Synthetic PR", author: "dani",
                             authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/1083")!,
                             headSha: head, headRef: "feature", baseRef: "main", body: "Tier: feature", isDraft: false,
                             labels: [], assignees: [], comments: [], updatedAt: ranAt)
        pr.checks = [CheckResult(name: "gate", state: .failure)]
        return pr
    }

    static func job(key: JobKey) -> Job {
        Job(id: UUID(), key: key, agent: "claude", startedAt: ranAt, status: .succeeded)
    }

    static func store(asked: Bool) -> CheckRerunStore {
        CheckRerunStore(reruns: [CheckRerun(repo: key.repo, number: 1083, head: head, at: ranAt, asked: asked)])
    }

    static func temporaryHome() -> BtonHome {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("check-moves-once-\(UUID().uuidString)")
        return BtonHome(environment: ["BTON_HOME": directory.path])
    }
}
