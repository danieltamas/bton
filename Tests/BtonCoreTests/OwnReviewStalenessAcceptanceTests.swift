import BtonCore
import Foundation
import Testing

private enum OwnReviewStalenessFixture {
    static let head = "abcdef123456" + String(repeating: "a", count: 28)
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ hours: Double) -> Date { epoch.addingTimeInterval(hours * 3600) }

    static func flow(who: String) throws -> Flow {
        let json: [String: Any] = [
            "version": 1, "base": "develop",
            "tier": ["marker": "Tier:", "values": ["high-risk"], "default": "high-risk"],
            "reviews": ["high-risk": [["heading": "## Review:", "notByAuthor": true]]],
            "fixed": "## Fixed:", "reviewers": ["alice", "bob", "carol"],
            "moves": [["move": "review", "when": ["no_review_or_response_newer"], "who": who]],
            "dispatch": ["review": ["agent": "review-agent", "prompt": "Review PR {number}"]],
        ]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func stale() throws -> Stale {
        try JSONDecoder().decode(Stale.self, from: Data("""
        {"pingHours":24,"escalateHours":48,"escalateTo":"synthetic-escalation"}
        """.utf8))
    }

    static func pr() -> PullRequest {
        var pr = PullRequest(repo: "synthetic/own-review-staleness", number: 17,
            title: "Synthetic PR", author: "alice", authorAssociation: "OWNER",
            url: URL(string: "https://github.com/synthetic/own-review-staleness/pull/17")!,
            headSha: head, headRef: "feature", baseRef: "develop", body: "**Tier:** high-risk",
            isDraft: false, labels: [], assignees: ["alice"], comments: [], updatedAt: at(0))
        pr.headCommittedAt = at(0)
        return pr
    }

    static func waitingPR(ownerWroteIt: Bool) -> PullRequest {
        var pr = pr()
        pr.move = Move(name: "review", owner: "alice", ownerFromRotation: false,
            tier: "high-risk", hasDispatch: true, labels: [], ownerWroteIt: ownerWroteIt)
        return pr
    }
}

struct OwnReviewStalenessAcceptanceTests {
    @Test func authorReviewRuleNeverFlagsItsAuthorOwner() throws {
        let pr = OwnReviewStalenessFixture.pr()
        let authorMove = try #require(FlowEngine.move(for: pr,
            flow: try OwnReviewStalenessFixture.flow(who: "author")))
        #expect(authorMove.name == "review")
        #expect(authorMove.owner == "alice")
        #expect(!authorMove.ownerWroteIt)

        let assigneeMove = try #require(FlowEngine.move(for: pr,
            flow: try OwnReviewStalenessFixture.flow(who: "assignee")))
        #expect(assigneeMove.name == "review")
        #expect(assigneeMove.owner == "alice")
        #expect(assigneeMove.ownerWroteIt)
    }

    @Test func flaggedReviewPingRequestsReviewerOtherThanAuthor() throws {
        let pr = OwnReviewStalenessFixture.waitingPR(ownerWroteIt: true)
        let notice = try #require(Staleness.notice(for: pr, stale: try OwnReviewStalenessFixture.stale(),
            now: OwnReviewStalenessFixture.at(25)))
        #expect(notice.marker == "stale-ping review@abcdef123456")
        #expect(notice.body == "@alice: `review` on abcdef1 has waited 25 hours for a reviewer other than its author.\n\n<!-- bton:stale-ping review@abcdef123456 -->")
    }

    @Test func flaggedReviewEscalationRequestsReviewerWithoutWaitingForOwner() throws {
        let pr = OwnReviewStalenessFixture.waitingPR(ownerWroteIt: true)
        let notice = try #require(Staleness.notice(for: pr, stale: try OwnReviewStalenessFixture.stale(),
            now: OwnReviewStalenessFixture.at(49)))
        #expect(notice.marker == "stale-escalate review@abcdef123456")
        #expect(notice.body == "@synthetic-escalation: `review` on abcdef1 has waited 49 hours for a reviewer other than its author.\n\n<!-- bton:stale-escalate review@abcdef123456 -->")
    }

    @Test func unflaggedReviewPingPreservesExistingWording() throws {
        let pr = OwnReviewStalenessFixture.waitingPR(ownerWroteIt: false)
        let notice = try #require(Staleness.notice(for: pr, stale: try OwnReviewStalenessFixture.stale(),
            now: OwnReviewStalenessFixture.at(25)))
        #expect(notice.marker == "stale-ping review@abcdef123456")
        #expect(notice.body == "@alice: `review` on abcdef1 has waited 25 hours.\n\n<!-- bton:stale-ping review@abcdef123456 -->")
    }

    @Test func unflaggedReviewEscalationPreservesExistingWording() throws {
        let pr = OwnReviewStalenessFixture.waitingPR(ownerWroteIt: false)
        let notice = try #require(Staleness.notice(for: pr, stale: try OwnReviewStalenessFixture.stale(),
            now: OwnReviewStalenessFixture.at(49)))
        #expect(notice.marker == "stale-escalate review@abcdef123456")
        #expect(notice.body == "@synthetic-escalation: `review` on abcdef1 has waited 49 hours for @alice.\n\n<!-- bton:stale-escalate review@abcdef123456 -->")
    }
}
