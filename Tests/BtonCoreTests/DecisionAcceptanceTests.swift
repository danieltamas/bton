@testable import BtonCore
import Foundation
import Testing

private enum DecisionFixture {
    static let head = "abcdef12" + String(repeating: "a", count: 32)

    static func flow(decision: Bool = true) throws -> Flow {
        var json: [String: Any] = [
            "version": 1, "base": "develop",
            "tier": ["marker": "Tier:", "values": ["feature", "high-risk"], "default": "feature"],
            "reviews": [
                "feature": [["heading": "## Review:", "notByAuthor": true]],
                "high-risk": [["heading": "## Review:", "notByAuthor": true]],
            ],
            "fixed": "## Fixed:",
            "moves": [
                ["move": "decide", "when": ["label:turn:lead"], "who": "owner-dev"],
                ["move": "finish", "when": ["draft"], "who": "author"],
                ["move": "review", "when": ["no_review_or_response_newer"], "who": "assignee"],
                ["move": "merge", "when": ["approved_current_head"], "who": "author"],
                ["move": "decide", "when": ["changes_rounds_at_least:2"], "who": "owner-dev"],
                ["move": "fix", "when": ["latest_review_changes_or_blocked"], "who": "author"],
            ],
            "dispatch": [:],
        ]
        if decision {
            json["decision"] = ["heading": "## Decision:", "move": "decide", "by": ["owner-dev"]]
        }
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func comment(_ body: String, author: String? = "reviewer-dev",
                        association: String? = "MEMBER", hour: Int = 12) -> PullRequestComment {
        PullRequestComment(author: author, authorAssociation: association, body: body,
                           createdAt: Date(timeIntervalSince1970: Double(hour * 3600)))
    }

    static var rounds: [PullRequestComment] {
        [comment("## Review: changes (head abcdef12)", hour: 12),
         comment("## Review: changes (head abcdef12)", hour: 13)]
    }

    static func decision(_ verdict: String, author: String? = "owner-dev",
                         association: String? = "OWNER", hour: Int = 14) -> PullRequestComment {
        comment("## Decision: \(verdict) (head abcdef12)", author: author,
                association: association, hour: hour)
    }

    static func pr(_ comments: [PullRequestComment] = [], author: String = "author-dev",
                   head: String = head, tier: String = "feature", draft: Bool = false,
                   labels: [String] = []) -> PullRequest {
        PullRequest(repo: "synthetic/decision", number: 7, title: "Synthetic PR", author: author,
                    authorAssociation: "OWNER", url: URL(string: "https://github.com/synthetic/decision/pull/7")!,
                    headSha: head, headRef: "feature", baseRef: "develop", body: "**Tier:** \(tier)",
                    isDraft: draft, labels: labels, assignees: ["reviewer-dev"],
                    comments: comments, updatedAt: .distantPast)
    }
}

struct DecisionAcceptanceTests {
    @Test func decisionHeadingMustBeNonemptyAndDistinctFromEveryTierReviewHeading() throws {
        for heading in ["", "## Review:", "## Review", "## Review: Decision", "## Decision:"] {
            let json: [String: Any] = [
                "version": 1, "base": "develop",
                "tier": ["marker": "Tier:", "values": ["feature", "high-risk"], "default": "feature"],
                "reviews": [
                    "feature": [["heading": "## Feature Review:"]],
                    "high-risk": [["heading": "## Review:"]],
                ],
                "fixed": "## Fixed:", "moves": [], "dispatch": [:],
                "decision": ["heading": heading, "move": "decide", "by": ["owner-dev"]],
            ]
            let status = Flow.load(try JSONSerialization.data(withJSONObject: json))
            if heading == "## Decision:" {
                guard case .ready = status else {
                    Issue.record("Distinct decision heading must load as ready"); continue
                }
                #expect(status.flow?.decision?.heading == heading)
            } else {
                #expect(status.flow == nil)
                guard case .invalid = status else {
                    Issue.record("Empty or overlapping decision heading must load as invalid: \(heading)")
                    continue
                }
            }
        }
    }

    @Test func decisionConfigurationDecodesAndRemainsOptional() throws {
        let flow = try DecisionFixture.flow()
        let decision: Flow.Decision = try #require(flow.decision)
        #expect(decision.heading == "## Decision:")
        #expect(decision.move == "decide")
        #expect(decision.by == ["owner-dev"])
        let legacy = try DecisionFixture.flow(decision: false)
        #expect(legacy.decision == nil)
        #expect(legacy.moves.map(\.move) == ["decide", "finish", "review", "merge", "decide", "fix"])
    }

    @Test(arguments: ["OWNER", "MEMBER", "COLLABORATOR"], ["approve", "changes", "blocked"])
    func trustedAllowlistedDecisionsCount(association: String, verdict: String) throws {
        let flow = try DecisionFixture.flow()
        let pr = DecisionFixture.pr([DecisionFixture.decision(verdict, author: "OwNeR-DeV", association: association)])
        let reviews = FlowEngine.reviews(of: pr, flow: flow)
        #expect(reviews.count == 1)
        let review = try #require(reviews.first)
        #expect(review.heading == "## Decision:")
        #expect(review.verdict.rawValue == verdict)
        #expect(review.head == "abcdef12")
    }

    @Test(arguments: ["CONTRIBUTOR", "NONE", "FIRST_TIMER", "UNKNOWN", "", "owner", nil] as [String?])
    func untrustedOrUnknownDecisionAssociationsAreIgnored(association: String?) throws {
        let pr = DecisionFixture.pr([DecisionFixture.decision("approve", association: association)])
        #expect(FlowEngine.reviews(of: pr, flow: try DecisionFixture.flow()).isEmpty)
    }

    @Test(arguments: [nil, "reviewer-dev"] as [String?])
    func missingOrUnlistedDecisionAuthorsAreIgnored(author: String?) throws {
        let pr = DecisionFixture.pr(DecisionFixture.rounds + [DecisionFixture.decision("approve", author: author)])
        let flow = try DecisionFixture.flow()
        #expect(FlowEngine.reviews(of: pr, flow: flow).count == 2)
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "decide")
    }

    @Test(arguments: ["Context\n## Decision: approve (head abcdef12)",
                      "## Decision: approved (head abcdef12)",
                      "## Decision: approve", "## Decision: approve (head xyz1234)"])
    func decisionRequiresValidFirstLine(body: String) throws {
        let pr = DecisionFixture.pr([DecisionFixture.comment(body, author: "owner-dev")])
        #expect(FlowEngine.reviews(of: pr, flow: try DecisionFixture.flow()).isEmpty)
    }

    @Test func orderedMovesKeepLabelAndDraftPrecedence() throws {
        let flow = try DecisionFixture.flow()
        let labelled = DecisionFixture.pr(draft: true, labels: ["turn:lead"])
        let decide = try #require(FlowEngine.move(for: labelled, flow: flow))
        #expect(decide.name == "decide")
        #expect(decide.owner == "owner-dev")
        #expect(decide.labels == ["turn:lead"])
        let finish = try #require(FlowEngine.move(for: DecisionFixture.pr(draft: true), flow: flow))
        #expect(finish.name == "finish")
        #expect(finish.owner == "author-dev")
        let review = try #require(FlowEngine.move(for: DecisionFixture.pr(), flow: flow))
        #expect(review.name == "review")
        #expect(review.owner == "reviewer-dev")
    }

    @Test func twoChangesReviewsRequireDecision() throws {
        let move = try #require(FlowEngine.move(for: DecisionFixture.pr(DecisionFixture.rounds),
                                              flow: DecisionFixture.flow()))
        #expect(move.name == "decide")
        #expect(move.owner == "owner-dev")
    }

    @Test(arguments: ["author-dev", "owner-dev"], ["feature", "high-risk"])
    func currentHeadDecisionApprovalMergesEvenForPRAuthor(author: String, tier: String) throws {
        let comments = DecisionFixture.rounds + [DecisionFixture.decision("approve")]
        let pr = DecisionFixture.pr(Array(comments.reversed()), author: author, tier: tier)
        let flow = try DecisionFixture.flow()
        let reviews = FlowEngine.reviews(of: pr, flow: flow)
        #expect(reviews.count == 3)
        #expect(reviews.last?.heading == "## Decision:")
        #expect(reviews.map(\.createdAt) == reviews.map(\.createdAt).sorted())
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "merge")
        #expect(move.owner == author)
        let selfReview = DecisionFixture.pr([
            DecisionFixture.comment("## Review: approve (head abcdef12)", author: author)
        ], author: author, tier: tier)
        #expect(FlowEngine.reviews(of: selfReview, flow: flow).isEmpty)
    }

    @Test(arguments: ["changes", "blocked"])
    func negativeDecisionResetsRoundsAndRequiresFix(verdict: String) throws {
        let flow = try DecisionFixture.flow()
        var comments = DecisionFixture.rounds + [DecisionFixture.decision(verdict)]
        let fix = try #require(FlowEngine.move(for: DecisionFixture.pr(comments), flow: flow))
        #expect(fix.name == "fix")
        #expect(fix.owner == "author-dev")
        comments.append(DecisionFixture.comment("## Fixed: addressed (head abcdef12)", author: "author-dev", hour: 15))
        #expect(FlowEngine.move(for: DecisionFixture.pr(comments), flow: flow)?.name == "review")
        comments.append(DecisionFixture.comment("## Review: changes (head abcdef12)", hour: 16))
        #expect(FlowEngine.move(for: DecisionFixture.pr(comments), flow: flow)?.name == "fix")
        comments.append(DecisionFixture.comment("## Review: changes (head abcdef12)", hour: 17))
        #expect(FlowEngine.move(for: DecisionFixture.pr(comments), flow: flow)?.name == "decide")
        // The latest decision, rather than the first, starts the next round window.
        comments.append(DecisionFixture.decision("changes", hour: 18))
        #expect(FlowEngine.move(for: DecisionFixture.pr(comments), flow: flow)?.name == "fix")
    }

    @Test func olderHeadDecisionApprovalRequiresReview() throws {
        let pr = DecisionFixture.pr(DecisionFixture.rounds + [DecisionFixture.decision("approve")],
                                    head: "12345678" + String(repeating: "b", count: 32))
        #expect(FlowEngine.move(for: pr, flow: try DecisionFixture.flow())?.name == "review")
    }

    @Test(arguments: ["approve", "changes", "blocked"])
    func flowWithoutDecisionKeepsRoundCap(verdict: String) throws {
        let flow = try DecisionFixture.flow(decision: false)
        let pr = DecisionFixture.pr(DecisionFixture.rounds + [DecisionFixture.decision(verdict)])
        #expect(FlowEngine.reviews(of: pr, flow: flow).count == 2)
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "decide")
    }

    @Test(arguments: ["decide", "review", "fix", "merge", "finish"])
    func dispatchHeadingsAndClearedLabelsFollowDecisionMove(name: String) throws {
        let move = Move(name: name, owner: "owner-dev", ownerFromRotation: false,
                        tier: "feature", hasDispatch: true, labels: ["turn:lead", "synthetic-label"])
        let flow = try DecisionFixture.flow()
        #expect(DispatchPlanner.commentHeadings(for: move, flow: flow)
                == (name == "decide" ? ["## Decision:"] : ["## Review:"]))
        #expect(DispatchPlanner.clearedLabels(for: move, flow: flow)
                == (name == "decide" ? move.labels : []))
        let legacy = try DecisionFixture.flow(decision: false)
        #expect(DispatchPlanner.commentHeadings(for: move, flow: legacy) == ["## Review:"])
        #expect(DispatchPlanner.clearedLabels(for: move, flow: legacy).isEmpty)
    }

    @Test func decisionFinalMessageRequiresDecisionHeading() throws {
        let message = "## Decision: approve (head abcdef12)\nSynthetic rationale."
        #expect(DispatchPlanner.reviewComment(fromFinalMessage: message, headings: ["## Decision:"],
                                              head: DecisionFixture.head) == message)
        #expect(DispatchPlanner.reviewComment(fromFinalMessage: message, headings: ["## Review:"],
                                              head: DecisionFixture.head) == nil)
    }

    @Test func reviewTargetClearLabelsDefaultsAndRoundTrips() throws {
        let legacy = ReviewTarget(number: 7, head: DecisionFixture.head, headings: ["## Review:"])
        #expect(legacy.clearLabels == nil)
        let target = ReviewTarget(number: 7, head: DecisionFixture.head, headings: ["## Decision:"],
                                  clearLabels: ["turn:lead"])
        let decoded = try JSONDecoder().decode(ReviewTarget.self, from: JSONEncoder().encode(target))
        #expect(decoded.clearLabels == ["turn:lead"])
        #expect(decoded == target)
    }

    @Test func olderJobWithoutClearLabelsDecodes() throws {
        let json = #"""
        {"id":"00000000-0000-0000-0000-000000000007",
         "key":{"repo":"synthetic/decision","item":"pr-7","move":"review","head":"abcdef12"},
         "agent":"synthetic-agent","startedAt":"2026-10-19T12:00:00Z","status":"running","usage":{},
         "review":{"number":7,"head":"abcdef12","headings":["## Review:"]}}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let job = try decoder.decode(Job.self, from: Data(json.utf8))
        let target = try #require(job.review)
        #expect(target.number == 7)
        #expect(target.headings == ["## Review:"])
        #expect(target.clearLabels == nil)
    }
}
