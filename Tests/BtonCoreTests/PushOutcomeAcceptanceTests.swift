@testable import BtonCore
import Foundation
import Testing

/// A fix job that ends with the PR still at the head it started on failed, whatever its agent
/// reported: the push is the PR's response, and a success there hid a blocked tool for a day.
@Suite(ProcessBound())
struct PushOutcomeAcceptanceTests {
    private enum HeadLookupError: Error { case unavailable }
    private static let head = "abcdef12" + String(repeating: "a", count: 32)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func changedHeadConfirmsThePush() async {
        let outcome = await DispatchPlanner.pushOutcome(startedAt: Self.head) { "pushed-head" }
        #expect(outcome.status == .succeeded)
        #expect(outcome.detail == nil)
    }

    @Test func unchangedHeadFailsWithEndedWithoutPushing() async throws {
        let outcome = await DispatchPlanner.pushOutcome(startedAt: Self.head) { Self.head }
        #expect(outcome.status == .failed)
        let detail = try #require(outcome.detail)
        #expect(detail.hasPrefix("ended without pushing"))
        #expect(detail.contains("abcdef12aaaa"))
        #expect(!detail.contains(Self.head), "the detail names the head short, as the rows do")
    }

    @Test func headLookupErrorFailsClosed() async throws {
        let outcome = await DispatchPlanner.pushOutcome(startedAt: Self.head) { throw HeadLookupError.unavailable }
        #expect(outcome.status == .failed)
        #expect(try #require(outcome.detail).hasPrefix("could not confirm the push"))
    }

    @Test func aFixThatPushedNothingCanBeRetriedAndIsAPlainFailure() async throws {
        let outcome = await DispatchPlanner.pushOutcome(startedAt: Self.head) { Self.head }
        let key = JobKey(repo: "synthetic/project", item: "pr-582", move: "fix", head: Self.head)
        var job = Job(id: UUID(), key: key, agent: "claude", startedAt: Self.now, endedAt: Self.now.addingTimeInterval(1),
                      status: outcome.status, detail: outcome.detail, retry: nil)
        job.pushes = true
        #expect(job.canRetry(among: [job]))
        #expect(Watchdog.flags(for: job, among: [job]) == [.failed])
        let verdict = try #require(Supervision.knownAnswer(for: job))
        #expect(verdict.action == .escalate, "the supervisor spends nothing on a cause Bton named itself")
        #expect(verdict.note.contains("press Retry"))
    }

    @Test func onlyTheFixRunByAnAgentMustPush() throws {
        let json: [String: Any] = [
            "version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:", "notByAuthor": true]]],
            "fixed": "## Fixed:",
            "moves": [
                ["move": "finish", "when": ["draft"], "who": "author"],
                ["move": "review", "when": ["no_review_or_response_newer"], "who": "assignee"],
                ["move": "merge", "when": ["approved_current_head"], "who": "author"],
                ["move": "fix", "when": ["latest_review_changes_or_blocked"], "who": "author"],
            ],
            "dispatch": [
                "finish": ["agent": "claude", "prompt": "Finish PR {number}."],
                "review": ["agent": "codex", "prompt": "Review PR {number}.", "post": "comment"],
                "merge": ["command": ["gh", "pr", "merge", "{number}"]],
                "fix": ["agent": "claude", "prompt": "Fix PR {number}."],
            ],
        ]
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
        let changes = Self.comment("## Review: changes (head abcdef12)")
        let approve = Self.comment("## Review: approve (head abcdef12)")
        func candidate(_ move: String, pr: PullRequest, me: String) throws -> DispatchCandidate {
            try #require(DispatchPlanner.candidates([pr], flow: flow, me: me, repo: "synthetic/project")
                .first { $0.key.move == move }, "\(move)")
        }

        #expect(try candidate("fix", pr: Self.pr([changes]), me: "dani").pushes,
                "the fix answers the review on the branch: its push is the response")
        #expect(!(try candidate("review", pr: Self.pr([]), me: "vlad").pushes), "a review answers with its comment")
        #expect(!(try candidate("merge", pr: Self.pr([approve]), me: "dani").pushes), "a command is judged by its exit status")
        #expect(!(try candidate("finish", pr: Self.pr([], draft: true), me: "dani").pushes),
                "another agent move may finish through gh or a comment with the head where it was")
    }

    private static func comment(_ body: String) -> PullRequestComment {
        PullRequestComment(author: "vlad", authorAssociation: "MEMBER", body: body,
                           createdAt: Date(timeIntervalSince1970: 1_761_774_000))
    }

    private static func pr(_ comments: [PullRequestComment], draft: Bool = false) -> PullRequest {
        PullRequest(repo: "synthetic/project", number: 582, title: "Synthetic PR", author: "dani",
                    authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/582")!,
                    headSha: head, headRef: "feature", baseRef: "main", body: "Tier: feature", isDraft: draft,
                    labels: [], assignees: ["vlad"], comments: comments, updatedAt: Date(timeIntervalSince1970: 1_761_773_000))
    }
}
