@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct CheckMovesOnceRetryAcceptanceTests {
    @Test(arguments: ["", "1794834600", "1794859781"])
    func isSameRunRequiresExactRoundWithoutAnyRound(round: String) {
        let key = CheckMovesOnceRetryFixture.key(round: round)

        #expect(DispatchPlanner.isSameRun(key, as: key, anyRound: false))
        for otherRound in CheckMovesOnceRetryFixture.rounds where otherRound != round {
            let other = CheckMovesOnceRetryFixture.key(round: otherRound)
            #expect(!DispatchPlanner.isSameRun(other, as: key, anyRound: false))
        }
    }

    @Test(arguments: ["", "1794834600", "1794859781"])
    func isSameRunMatchesAnyRoundOnSameRepoItemMoveAndHead(round: String) {
        let key = CheckMovesOnceRetryFixture.key(round: round)

        for otherRound in CheckMovesOnceRetryFixture.rounds {
            let other = CheckMovesOnceRetryFixture.key(round: otherRound)
            #expect(DispatchPlanner.isSameRun(other, as: key, anyRound: true))
        }
    }

    @Test(arguments: [true, false])
    func isSameRunRejectsAnotherRepoItemMoveOrHead(anyRound: Bool) {
        let key = CheckMovesOnceRetryFixture.key()

        for round in CheckMovesOnceRetryFixture.rounds {
            let unrelated = [
                CheckMovesOnceRetryFixture.key(repo: "synthetic/other", round: round),
                CheckMovesOnceRetryFixture.key(item: "pr-2", round: round),
                CheckMovesOnceRetryFixture.key(move: "fix", round: round),
                // The same abbreviated SHA is still a different full head.
                CheckMovesOnceRetryFixture.key(
                    head: String(CheckMovesOnceRetryFixture.head.dropLast()) + "b", round: round)
            ]
            for other in unrelated {
                #expect(!DispatchPlanner.isSameRun(other, as: key, anyRound: anyRound))
            }
        }
    }

    @Test func isRetryAcrossRoundsAcceptsOnlyRoundedRetriedJob() {
        let job = CheckMovesOnceRetryFixture.job(round: "1794834600", retry: true)

        #expect(DispatchPlanner.isRetry(CheckMovesOnceRetryFixture.key(),
            jobs: [job], anyRound: true))
    }

    @Test(arguments: ["", "1794834600", "1794859781"])
    func isRetryAcrossRoundsRejectsAnyNonRetriedJob(round: String) {
        let retried = CheckMovesOnceRetryFixture.job(round: "1794834600", retry: true)

        for retry in [nil, false] as [Bool?] {
            let other = CheckMovesOnceRetryFixture.job(round: round, retry: retry)
            for jobs in [[retried, other], [other, retried]] {
                #expect(!DispatchPlanner.isRetry(CheckMovesOnceRetryFixture.key(),
                    jobs: jobs, anyRound: true))
            }
        }
    }

    @Test func isRetryAcrossRoundsRejectsNoJobs() {
        #expect(!DispatchPlanner.isRetry(CheckMovesOnceRetryFixture.key(),
            jobs: [], anyRound: true))
    }

    @Test func roundlessKeyIsNotRetryWithoutAnyRound() {
        let job = CheckMovesOnceRetryFixture.job(round: "1794834600", retry: true)

        #expect(!DispatchPlanner.isRetry(CheckMovesOnceRetryFixture.key(), jobs: [job]))
        #expect(!DispatchPlanner.isRetry(CheckMovesOnceRetryFixture.key(),
            jobs: [job], anyRound: false))
    }

    @Test func selectStartsUnpressedFixCIWithOnlyRoundedRetriedJob() throws {
        let flow = try CheckMovesOnceRetryFixture.flow()
        let pr = CheckMovesOnceRetryFixture.pr()
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.move.name == "fix-ci")
        #expect(candidate.answersChecks)
        #expect(!candidate.pressed)
        #expect(candidate.key == CheckMovesOnceRetryFixture.key())
        let job = CheckMovesOnceRetryFixture.job(round: "1794834600", retry: true)

        let selected = DispatchPlanner.select(candidates, jobs: [job], maxAgents: 1,
            agents: CheckMovesOnceRetryFixture.agents, first: [], now: CheckMovesOnceRetryFixture.now)

        #expect(selected.map(\.key) == [candidate.key])
        #expect(selected.allSatisfy { !$0.pressed })
    }
}

private enum CheckMovesOnceRetryFixture {
    static let repo = "synthetic/project"
    static let head = "fa1fbb9d" + String(repeating: "a", count: 32)
    static let rounds = ["", "1794834600", "1794859781"]
    static let startedAt = Date(timeIntervalSince1970: 1_794_834_600)
    static let now = Date(timeIntervalSince1970: 1_794_859_781)
    static let agents = ["claude": AgentTemplate(argv: ["/usr/bin/true", "{prompt}"])]

    static func key(repo: String = CheckMovesOnceRetryFixture.repo, item: String = "pr-1",
                    move: String = "fix-ci", head: String = CheckMovesOnceRetryFixture.head,
                    round: String = "") -> JobKey {
        JobKey(repo: repo, item: item, move: move, head: head, round: round)
    }

    static func job(round: String, retry: Bool?) -> Job {
        Job(id: UUID(), key: key(round: round), agent: "claude", startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60), status: .failed, retry: retry)
    }

    static func flow() throws -> Flow {
        let json: [String: Any] = [
            "version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:", "notByAuthor": false]]],
            "fixed": "## Fixed:",
            "decision": ["heading": "## Decision:", "move": "decide", "by": ["dani"]],
            "moves": [["move": "fix-ci", "when": ["checks_red:gate"], "who": "author"]],
            "dispatch": ["fix-ci": ["agent": "claude", "prompt": "Handle PR {number}."]]
        ]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func pr() -> PullRequest {
        var pr = PullRequest(repo: repo, number: 1, title: "Synthetic PR", author: "dani",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/1")!,
            headSha: head, headRef: "feature", baseRef: "main", body: "Tier: feature", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: now)
        pr.checks = [CheckResult(name: "gate", state: .failure)]
        return pr
    }
}
