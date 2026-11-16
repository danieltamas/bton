@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct CheckMovesOnceDeltaAcceptanceTests {
    @Test(arguments: [true, false])
    func leaseHasRunRequiresExactMergeKey(inCurrentKey: Bool) {
        let key = "synthetic/project#pr-1 merge@fa1fbb9daaaa"
        let rounded = key + "/1794859781"
        let record = CheckMovesOnceDeltaFixture.lease(
            key: inCurrentKey ? rounded : nil, done: inCurrentKey ? nil : [rounded])

        #expect(record.hasRun(rounded))
        #expect(!record.hasRun(key))
    }

    @Test(arguments: [true, false])
    func leaseHasRunUnderRoundFindsFixCIInCurrentAndDoneKeys(inCurrentKey: Bool) {
        let key = "synthetic/project#pr-1 fix-ci@fa1fbb9daaaa"
        let rounded = key + "/1794859781"
        let record = CheckMovesOnceDeltaFixture.lease(
            key: inCurrentKey ? rounded : nil, done: inCurrentKey ? nil : [rounded])

        #expect(record.hasRunUnderRound(key))
        #expect(!record.hasRun(key))
    }

    @Test func leaseHasRunUnderRoundIsFalseWithoutMatchingRoundedRecord() {
        let key = "synthetic/project#pr-1 fix-ci@fa1fbb9daaaa"
        let empty = CheckMovesOnceDeltaFixture.lease(key: nil, done: nil)
        let exactOnly = CheckMovesOnceDeltaFixture.lease(key: key, done: [key])
        let unrelated = CheckMovesOnceDeltaFixture.lease(
            key: "synthetic/project#pr-1 merge@fa1fbb9daaaa/1794859781",
            done: ["synthetic/project#pr-1 fix-ci@bbbbbbbbbbbb/1794859781"])

        #expect(exactOnly.hasRun(key))
        for record in [empty, exactOnly, unrelated] {
            #expect(!record.hasRunUnderRound(key))
        }
    }

    @Test(arguments: ["dani", "vlad"])
    func reviewFixDoesNotAnswerChecksAndStartsAfterOlderRound(reviewer: String) throws {
        let flow = try CheckMovesOnceDeltaFixture.flow(
            move: "fix", when: ["latest_review_changes_or_blocked"])
        var pr = CheckMovesOnceDeltaFixture.pr()
        pr.comments = [PullRequestComment(author: reviewer, authorAssociation: "MEMBER",
            body: "## Review: changes (head fa1fbb9d)\nSynthetic review.",
            createdAt: CheckMovesOnceDeltaFixture.now)]
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.move.name == "fix")
        #expect(candidate.answersChecks == false)
        // An author's own counting review creates no round. It still needs a fix.
        #expect(candidate.key.round == (reviewer == pr.author ? "" : "1794859781"))
        let olderKey = JobKey(repo: pr.repo, item: "pr-1", move: "fix", head: pr.headSha,
                              round: "1794834600")
        let olderJob = CheckMovesOnceDeltaFixture.job(key: olderKey)
        #expect(candidate.key != olderKey)
        #expect(DispatchPlanner.select(candidates, jobs: [olderJob], maxAgents: 1,
            agents: CheckMovesOnceDeltaFixture.agents).map(\.key) == [candidate.key])
    }

    @Test func redCheckFixCICandidateAnswersChecks() throws {
        let flow = try CheckMovesOnceDeltaFixture.flow(move: "fix-ci", when: ["checks_red:gate"])
        let pr = CheckMovesOnceDeltaFixture.pr(state: .failure)
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)

        #expect(candidate.move.name == "fix-ci")
        #expect(candidate.answersChecks == true)
        #expect(candidate.key.round.isEmpty)
    }

    @Test func takenAskWhoseGateTurnsGreenProducesOneFlake() {
        let flakes = CheckMovesOnceDeltaFixture.afterRerun(CheckMovesOnceDeltaFixture.reruns())

        #expect(flakes == [CheckMovesOnceDeltaFixture.flake])
    }

    @Test func untakenAskDoesNotProduceAFlake() {
        #expect(CheckMovesOnceDeltaFixture.afterRerun(
            CheckMovesOnceDeltaFixture.reruns(asked: false)).isEmpty)
    }

    @Test(arguments: [CheckResult.State.failure, .pending])
    func failedOrPendingGateDoesNotProduceAFlake(state: CheckResult.State) {
        #expect(CheckMovesOnceDeltaFixture.afterRerun(CheckMovesOnceDeltaFixture.reruns(),
            pr: CheckMovesOnceDeltaFixture.pr(state: state)).isEmpty)
    }

    @Test func greenCheckOutsideAskDoesNotProduceAFlake() {
        #expect(CheckMovesOnceDeltaFixture.afterRerun(
            CheckMovesOnceDeltaFixture.reruns(checks: ["other-check"])).isEmpty)
    }

    @Test func alreadyRecordedRepoCheckAndHeadDoesNotProduceAFlake() {
        let store = FlakeStore(flakes: [CheckMovesOnceDeltaFixture.flake])
        #expect(CheckMovesOnceDeltaFixture.afterRerun(CheckMovesOnceDeltaFixture.reruns(),
            store: store).isEmpty)
    }

    @Test func greenGateOnAnotherHeadDoesNotProduceAFlake() {
        let pr = CheckMovesOnceDeltaFixture.pr(head: String(repeating: "b", count: 40))
        #expect(CheckMovesOnceDeltaFixture.afterRerun(CheckMovesOnceDeltaFixture.reruns(), pr: pr).isEmpty)
    }

    @Test func settlingFlakePreventsRediscoveryAndPreservesOneAsk() throws {
        let reruns = CheckMovesOnceDeltaFixture.reruns()
        let flakes = CheckMovesOnceDeltaFixture.afterRerun(reruns)
        #expect(flakes == [CheckMovesOnceDeltaFixture.flake])
        let settled = reruns.settling(flakes)

        #expect(CheckMovesOnceDeltaFixture.afterRerun(settled, store: FlakeStore()).isEmpty)
        let ask = try #require(settled.rerun(repo: CheckMovesOnceDeltaFixture.repo,
                                           head: CheckMovesOnceDeltaFixture.head))
        #expect(ask.asked)
        #expect(ask.checks.isEmpty)
        #expect(ask.number == 1)
        #expect(ask.at == CheckMovesOnceDeltaFixture.askedAt)
        for elapsed in [0.0, CheckReruns.settle - 1, CheckReruns.settle,
                        CheckReruns.settle + 1, 31 * 86400] as [TimeInterval] {
            #expect(CheckReruns.step(for: CheckMovesOnceDeltaFixture.key, failedChecks: ["gate"],
                pressed: false, jobs: [], store: settled,
                now: ask.at.addingTimeInterval(elapsed)) != .ask)
        }
    }
}

private enum CheckMovesOnceDeltaFixture {
    static let repo = "synthetic/project"
    static let head = "fa1fbb9d" + String(repeating: "a", count: 32)
    static let askedAt = Date(timeIntervalSince1970: 1_794_834_600)
    static let now = Date(timeIntervalSince1970: 1_794_859_781)
    static let key = JobKey(repo: repo, item: "pr-1", move: "fix-ci", head: head)
    static let agents = ["claude": AgentTemplate(argv: ["/usr/bin/true", "{prompt}"])]
    static let flake = Flake(repo: repo, check: "gate", number: 1, head: head, at: now)

    static func lease(key: String?, done: [String]?) -> LeaseRecord {
        LeaseRecord(holder: "synthetic", host: "fixture", job: UUID(),
            expires: Date(timeIntervalSince1970: 100), released: true, key: key, done: done)
    }

    static func flow(move: String, when predicates: [String]) throws -> Flow {
        let json: [String: Any] = [
            "version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:", "notByAuthor": false]]],
            "fixed": "## Fixed:",
            "decision": ["heading": "## Decision:", "move": "decide", "by": ["dani"]],
            "moves": [["move": move, "when": predicates, "who": "author"]],
            "dispatch": [move: ["agent": "claude", "prompt": "Handle PR {number}."]]
        ]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func pr(head: String = CheckMovesOnceDeltaFixture.head,
                   state: CheckResult.State = .success) -> PullRequest {
        var pr = PullRequest(repo: repo, number: 1, title: "Synthetic PR", author: "dani",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/1")!,
            headSha: head, headRef: "feature", baseRef: "main", body: "Tier: feature", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: now)
        pr.checks = [CheckResult(name: "gate", state: state)]
        return pr
    }

    static func job(key: JobKey) -> Job {
        Job(id: UUID(), key: key, agent: "claude", startedAt: askedAt, status: .succeeded)
    }

    static func reruns(asked: Bool = true, checks: [String] = ["gate"]) -> CheckRerunStore {
        CheckRerunStore(reruns: [CheckRerun(repo: repo, number: 1, head: head,
                                          at: askedAt, asked: asked, checks: checks)])
    }

    static func afterRerun(_ reruns: CheckRerunStore, pr: PullRequest = CheckMovesOnceDeltaFixture.pr(),
                           store: FlakeStore = FlakeStore()) -> [Flake] {
        Flakes.afterRerun(reruns, store: store, pullRequests: [pr], repo: repo, now: now)
    }
}
