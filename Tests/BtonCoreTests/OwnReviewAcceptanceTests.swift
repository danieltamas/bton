import BtonCore
import Foundation
import Testing

private enum OwnReviewFixture {
    static let head = "abcdef12" + String(repeating: "a", count: 32)

    static func flow(highRiskReviews: [[String: Any]] = [
        ["heading": "## Review:", "notByAuthor": true]
    ]) throws -> Flow {
        let json: [String: Any] = [
            "version": 1, "base": "develop",
            "tier": ["marker": "Tier:", "values": ["quick fix", "feature", "high-risk"],
                     "default": "feature"],
            "reviews": [
                "quick fix": [["heading": "## Review:"]],
                "high-risk": highRiskReviews,
            ],
            "fixed": "## Fixed:",
            "reviewers": ["alice", "bob", "carol"],
            "moves": [
                ["move": "review", "when": ["no_review_or_response_newer"], "who": "assignee"],
                ["move": "merge", "when": ["approved_current_head"], "who": "assignee"],
            ],
            "dispatch": [
                "review": ["agent": "review-agent", "prompt": "Review PR {number}"],
                "merge": ["command": ["echo", "merge", "{number}"]],
            ],
        ]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func approval(by author: String) -> PullRequestComment {
        PullRequestComment(author: author, authorAssociation: "MEMBER",
                           body: "## Review: approve (head abcdef12)",
                           createdAt: Date(timeIntervalSince1970: 3600))
    }

    static func pr(tier: String = "high-risk", assignees: [String] = ["alice"],
                   number: Int = 7, comments: [PullRequestComment] = []) -> PullRequest {
        PullRequest(repo: "synthetic/own-review", number: number, title: "Synthetic PR", author: "alice",
                    authorAssociation: "OWNER",
                    url: URL(string: "https://github.com/synthetic/own-review/pull/\(number)")!,
                    headSha: head, headRef: "feature", baseRef: "develop", body: "**Tier:** \(tier)",
                    isDraft: false, labels: [], assignees: assignees,
                    comments: comments, updatedAt: .distantPast)
    }
}

struct OwnReviewAcceptanceTests {
    @Test(arguments: ["alice", "ALICE"])
    func authorAssignedAnIndependentReviewCannotDispatch(me: String) throws {
        let flow = try OwnReviewFixture.flow()
        let pr = OwnReviewFixture.pr()
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.owner == "alice")
        #expect(move.ownerWroteIt)
        #expect(!FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: me))
    }

    @Test func anotherAssigneeCanDispatchIndependentReview() throws {
        let flow = try OwnReviewFixture.flow()
        let pr = OwnReviewFixture.pr(assignees: ["bob"])
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.owner == "bob")
        #expect(!move.ownerWroteIt)
        #expect(FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: "bob"))
    }

    @Test(arguments: 6...11)
    func unassignedReviewRotatesToSomeoneOtherThanAuthor(number: Int) throws {
        let flow = try OwnReviewFixture.flow()
        let pr = OwnReviewFixture.pr(assignees: [], number: number)
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        let owner = try #require(move.owner)
        #expect(move.name == "review")
        #expect(["bob", "carol"].contains(owner))
        #expect(!move.ownerWroteIt)
        #expect(FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: owner))
    }

    @Test func quickFixAllowsAuthorReview() throws {
        let flow = try OwnReviewFixture.flow()
        let pr = OwnReviewFixture.pr(tier: "quick fix")
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.owner == "alice")
        #expect(!move.ownerWroteIt)
        #expect(FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: "alice"))
    }

    @Test func independentApprovalAllowsAuthorToMerge() throws {
        let flow = try OwnReviewFixture.flow()
        let pr = OwnReviewFixture.pr(comments: [OwnReviewFixture.approval(by: "bob")])
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "merge")
        #expect(move.owner == "alice")
        #expect(!move.ownerWroteIt)
        #expect(FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: "alice"))
    }

    @Test func authorComparisonIgnoresCaseAndPreservesAssignee() throws {
        let flow = try OwnReviewFixture.flow()
        let pr = OwnReviewFixture.pr(assignees: ["Alice"])
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.owner == "Alice")
        #expect(move.ownerWroteIt)
        #expect(!FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: "Alice"))
    }

    @Test func authorsOwnApprovalDoesNotClearIndependentReview() throws {
        let flow = try OwnReviewFixture.flow()
        let pr = OwnReviewFixture.pr(comments: [OwnReviewFixture.approval(by: "alice")])
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.owner == "alice")
        #expect(move.ownerWroteIt)
        #expect(!FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: "alice"))
    }

    @Test func emptyOrMissingTierReviewsDoNotFlagAuthor() throws {
        let flow = try OwnReviewFixture.flow(highRiskReviews: [])
        for tier in ["high-risk", "feature"] {
            let pr = OwnReviewFixture.pr(tier: tier)
            let move = try #require(FlowEngine.move(for: pr, flow: flow))
            #expect(move.name == "review")
            #expect(move.owner == "alice")
            #expect(!move.ownerWroteIt)
        }
    }

    @Test(arguments: [false, true])
    func everyReviewHeadingMustExcludeAuthor(explicitFalse: Bool) throws {
        var authorAllowed: [String: Any] = ["heading": "## Additional review:"]
        if explicitFalse { authorAllowed["notByAuthor"] = false }
        let flow = try OwnReviewFixture.flow(highRiskReviews: [
            ["heading": "## Review:", "notByAuthor": true], authorAllowed,
        ])
        let pr = OwnReviewFixture.pr()
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.owner == "alice")
        #expect(!move.ownerWroteIt)
        #expect(FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: "alice"))
    }

    @Test func dispatchHonorsFlagEvenForOtherwiseDispatchableMerge() throws {
        let flow = try OwnReviewFixture.flow()
        let pr = OwnReviewFixture.pr(comments: [OwnReviewFixture.approval(by: "bob")])
        let ordinary = Move(name: "merge", owner: "alice", ownerFromRotation: false,
                            tier: "high-risk", hasDispatch: true, labels: [])
        let flagged = Move(name: "merge", owner: "alice", ownerFromRotation: false,
                           tier: "high-risk", hasDispatch: true, labels: [], ownerWroteIt: true)
        #expect(!ordinary.ownerWroteIt)
        #expect(FlowEngine.isDispatchable(ordinary, pr: pr, flow: flow, me: "alice"))
        #expect(!FlowEngine.isDispatchable(flagged, pr: pr, flow: flow, me: "alice"))
    }
}
