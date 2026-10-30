@testable import BtonCore
import Foundation
import Testing

struct ApproverOwnerAcceptanceTests {
    @Test(arguments: ["who", "owner"])
    func approvalImmediatelyBelongsToItsReviewer(field: String) throws {
        let flow = try ApproverFixture.flow(field: field)
        let pr = ApproverFixture.pr(comments: [ApproverFixture.comment("danieltamas", "approve", at: 10)])
        #expect(pr.requestedReviewers.isEmpty)
        #expect(pr.assignees.isEmpty)
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "merge")
        #expect(move.owner == "danieltamas")
        #expect(!move.ownerFromRotation)
        for me in ["danieltamas", "DANIELTAMAS"] {
            let candidates = DispatchPlanner.candidates([pr], flow: flow, me: me, repo: pr.repo)
            #expect(candidates.count == 1)
            #expect(candidates.first?.move.name == "merge")
            #expect(candidates.first?.move.owner == "danieltamas")
        }
        #expect(DispatchPlanner.candidates([pr], flow: flow, me: "vladnegrean14", repo: pr.repo).isEmpty)
    }

    @Test func latestDecisionCountsAsApprover() throws {
        let flow = try ApproverFixture.flow()
        // Reverse storage order ensures creation time decides ownership.
        let pr = ApproverFixture.pr(comments: [
            ApproverFixture.comment("danieltamas", "approve", heading: "## Decision:", at: 20),
            ApproverFixture.comment("vladnegrean14", "changes", at: 10)
        ])
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "merge")
        #expect(move.owner == "danieltamas")
        #expect(!move.ownerFromRotation)
    }

    @Test(arguments: ["who", "owner"])
    func ownerKindResolvesPerTier(field: String) throws {
        let flow = try ApproverFixture.flow(who: ["quick fix": "author", "feature": "approver"],
                                            field: field, when: [])
        for tier in ["quick fix", "feature"] {
            let pr = ApproverFixture.pr(tier: tier, comments: [
                ApproverFixture.comment("danieltamas", "approve", at: 10)
            ])
            let move = try #require(FlowEngine.move(for: pr, flow: flow))
            #expect(move.owner == (tier == "feature" ? "danieltamas" : "bogdanIuga"))
            #expect(!move.ownerFromRotation)
        }
    }

    @Test func noCountingReviewLeavesMoveUnassigned() throws {
        let flow = try ApproverFixture.flow(when: [])
        let pr = ApproverFixture.pr(comments: [
            ApproverFixture.comment("bogdanIuga", "approve", at: 10),
            ApproverFixture.comment("outsider", "approve", at: 20, association: "CONTRIBUTOR"),
            ApproverFixture.comment("vladnegrean14", "approve", heading: "## Decision:", at: 30)
        ])
        #expect(FlowEngine.reviews(of: pr, flow: flow).isEmpty)
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "merge")
        #expect(move.owner == nil)
        #expect(!move.ownerFromRotation)
        for me in ["danieltamas", "bogdanIuga", "vladnegrean14", "approver", "outsider"] {
            #expect(DispatchPlanner.candidates([pr], flow: flow, me: me, repo: pr.repo).isEmpty)
        }
    }

    @Test(arguments: ["approve", "changes", "blocked"])
    func approverMoveCannotBeTaken(verdict: String) throws {
        let flow = try ApproverFixture.flow(when: [])
        let pr = ApproverFixture.pr(comments: [
            ApproverFixture.comment("vladnegrean14", "approve", at: 10),
            ApproverFixture.comment("danieltamas", verdict, at: 20)
        ])
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.owner == "danieltamas")
        #expect(!move.ownerFromRotation)
        #expect(FlowEngine.takeover(of: pr, flow: flow, me: "vladnegrean14") == nil)
    }

    @Test func automaticTakeRetriesWhenReviewBecomesMergeAtSameOwnerAndHead() throws {
        let flow = try ApproverFixture.flow(who: "reviewer")
        var review = ApproverFixture.pr()
        review.move = Move(name: "review", owner: "VladNegrean14", ownerFromRotation: true,
                           tier: "feature", hasDispatch: true)
        var merge = ApproverFixture.pr(comments: [ApproverFixture.comment("danieltamas", "approve", at: 10)])
        merge.move = Move(name: "merge", owner: "VladNegrean14", ownerFromRotation: true,
                          tier: "feature", hasDispatch: true)
        let pick = Engine.pick(repo: review.repo, item: "pr-599")
        let reviewKey = Engine.autoTakeKey(review, repo: review.repo)
        let mergeKey = Engine.autoTakeKey(merge, repo: merge.repo)
        #expect(reviewKey == "\(pick)@vladnegrean14@review@\(review.headSha)")
        #expect(mergeKey == "\(pick)@vladnegrean14@merge@\(merge.headSha)")
        #expect(reviewKey != mergeKey)
        let offered = Engine.autoTakeable([merge], flow: flow, me: "danieltamas", repo: merge.repo,
                                           tried: [reviewKey])
        #expect(offered.map(\.number) == [599])
        #expect(Engine.autoTakeable([merge], flow: flow, me: "danieltamas", repo: merge.repo,
                                    tried: [mergeKey]).isEmpty)
    }
}

private enum ApproverFixture {
    static let head = String(repeating: "a", count: 40)

    static func flow(who: Any = "approver", field: String = "who",
                     when: [String] = ["approved_current_head", "checks_green:gate"]) throws -> Flow {
        var rule: [String: Any] = ["move": "merge", "when": when, "who": "assignee"]
        rule[field] = who
        let object: [String: Any] = ["version": 1, "base": "develop",
            "tier": ["marker": "Tier:", "values": ["quick fix", "feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:", "notByAuthor": true]]],
            "decision": ["heading": "## Decision:", "move": "decide", "by": ["danieltamas"]],
            "fixed": "## Fixed:", "reviewers": ["danieltamas", "bogdanIuga", "vladnegrean14"],
            "moves": [rule], "dispatch": ["merge": ["agent": "synthetic", "prompt": "Merge"]]]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func pr(tier: String = "feature", comments: [PullRequestComment] = []) -> PullRequest {
        var pr = PullRequest(repo: "synthetic/lexito", number: 599, title: "Synthetic PR", author: "bogdanIuga",
            authorAssociation: "MEMBER", url: URL(string: "https://example.invalid/pr/599")!,
            headSha: head, headRef: "feature", baseRef: "develop", body: "Tier: \(tier)",
            isDraft: false, labels: [], assignees: [], comments: comments,
            updatedAt: Date(timeIntervalSince1970: 1_792_411_200))
        pr.checks = [CheckResult(name: "gate", state: .success)]
        return pr
    }

    static func comment(_ author: String, _ verdict: String, heading: String = "## Review:",
                        at time: TimeInterval, association: String = "MEMBER") -> PullRequestComment {
        PullRequestComment(author: author, authorAssociation: association,
            body: "\(heading) \(verdict) (head \(head))", createdAt: Date(timeIntervalSince1970: time))
    }
}
