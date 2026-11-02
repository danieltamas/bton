@testable import BtonCore
import Testing
import Foundation

@Suite(ProcessBound())
struct ReviewWaitsForChecksAcceptanceTests {
    @Test func moveDefaultsToNoPendingChecks() {
        let move = Move(name: "review", owner: "owner", ownerFromRotation: false,
                        tier: "feature", hasDispatch: true, redChecks: [])
        #expect(move.pendingChecks == [])
    }

    @Test func pendingNamesFollowHeadThenEveryRuleWithoutRepeats() throws {
        let flow = try ReviewWaitsFixture.flow(mergePredicates: [
            "approved_current_head", "checks_green: gate , queued , gate ", "checks_green:lint,queued"
        ], extraMoves: [
            ["move": "ready", "when": ["checks_green:security,lint"], "who": "author"]
        ])
        var pr = ReviewWaitsFixture.pr()
        pr.checks = [CheckResult(name: "tests", state: .pending),
                     CheckResult(name: "finished", state: .success),
                     CheckResult(name: "gate", state: .pending),
                     CheckResult(name: "tests", state: .pending),
                     CheckResult(name: "red", state: .failure)]
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.pendingChecks == ["tests", "gate", "queued", "lint", "security"])
        #expect(move.redChecks == [])
        #expect(!move.hasDispatch)
    }

    @Test(arguments: ["pending", "missing", "both"])
    func heldReviewKeepsItsMoveAndCannotDispatch(scenario: String) throws {
        let flow = try ReviewWaitsFixture.flow()
        var pr = ReviewWaitsFixture.pr()
        switch scenario {
        case "pending":
            pr.checks = [CheckResult(name: "gate", state: .pending)]
        case "both":
            pr.checks = [CheckResult(name: "tests", state: .pending)]
        default: pr.checks = []
        }
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.owner == pr.author)
        #expect(!move.ownerFromRotation)
        #expect(move.tier == "feature")
        #expect(move.labels == [])
        #expect(!move.ownerWroteIt)
        #expect(move.tierReason == nil)
        #expect(move.redChecks == [])
        #expect(move.pendingChecks == (scenario == "both" ? ["tests", "gate"] : ["gate"]))
        #expect(!move.hasDispatch)
        #expect(!FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: pr.author))
        #expect(DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo).isEmpty)
    }

    @Test func heldReviewPreservesRotationLabelsAndRaisedTier() throws {
        let flow = try ReviewWaitsFixture.flow(decorated: true)
        var pr = ReviewWaitsFixture.pr()
        pr.labels = ["needs-review"]
        pr.changedFiles = ["Sources/Important.swift"]
        pr.checks = [CheckResult(name: "gate", state: .success)]
        let ready = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(ready.hasDispatch)
        #expect(ready.owner == "reviewer")
        #expect(ready.ownerFromRotation)
        #expect(ready.tier == "careful")
        #expect(ready.labels == ["needs-review"])
        #expect(ready.tierReason != nil)
        pr.checks = [CheckResult(name: "gate", state: .pending)]
        let held = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(held.name == ready.name)
        #expect(held.owner == ready.owner)
        #expect(held.ownerFromRotation == ready.ownerFromRotation)
        #expect(held.tier == ready.tier)
        #expect(held.labels == ready.labels)
        #expect(held.ownerWroteIt == ready.ownerWroteIt)
        #expect(held.tierReason == ready.tierReason)
        #expect(held.pendingChecks == ["gate"])
        #expect(held.redChecks == [])
        #expect(!held.hasDispatch)
    }

    @Test(arguments: ["green", "red gate", "red unrelated", "all red"])
    func completedChecksAllowReviewAndPlanner(scenario: String) throws {
        let flow = try ReviewWaitsFixture.flow()
        var pr = ReviewWaitsFixture.pr()
        pr.checks = [
            CheckResult(name: "gate", state: scenario == "red gate" || scenario == "all red" ? .failure : .success),
            CheckResult(name: "tests", state: scenario == "red unrelated" || scenario == "all red" ? .failure : .success)
        ]
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.owner == pr.author)
        #expect(move.hasDispatch)
        #expect(move.pendingChecks == [])
        #expect(move.redChecks == [])
        #expect(FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: pr.author))
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.move == move)
        #expect(candidate.pr?.number == pr.number)
        #expect(candidate.agent == "codex")
    }

    @Test func noKnownChecksDoesNotHoldReview() throws {
        let flow = try ReviewWaitsFixture.flow(includeMerge: false)
        let pr = ReviewWaitsFixture.pr()
        #expect(pr.checks.isEmpty)
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.hasDispatch)
        #expect(move.pendingChecks == [])
        #expect(DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo).count == 1)
    }

    /// Review finding (Codex, 2026-11-02): a flow that names no check cannot tell a head pushed
    /// moments ago, whose runs GitHub has not registered, from a repo without CI. Such a head is
    /// held for two minutes after the PR last changed; a named or present check decides instead.
    @Test(arguments: [0.0, 119.0, 120.0, 3_600.0])
    func aFreshHeadWithNoChecksWaitsForRegistrationOnlyInAFlowNamingNone(age: TimeInterval) throws {
        var pr = ReviewWaitsFixture.pr(age: age)
        let held = age < 120
        let unnamed = try ReviewWaitsFixture.flow(includeMerge: false)
        let move = try #require(FlowEngine.move(for: pr, flow: unnamed))
        #expect(move.pendingChecks == (held ? ["checks to register"] : []))
        #expect(move.hasDispatch == !held)
        #expect(DispatchPlanner.candidates([pr], flow: unnamed, me: pr.author, repo: pr.repo).count == (held ? 0 : 1))
        // A flow naming `gate` holds on the name, never on the clock; a present check decides on its own.
        #expect(FlowEngine.move(for: pr, flow: try ReviewWaitsFixture.flow())?.pendingChecks == ["gate"])
        pr.checks = [CheckResult(name: "other", state: .success)]
        #expect(FlowEngine.move(for: pr, flow: unnamed)?.pendingChecks == [])
        pr.checks = [CheckResult(name: "other", state: .pending)]
        #expect(FlowEngine.move(for: pr, flow: unnamed)?.pendingChecks == ["other"])
    }

    @Test(arguments: ["pending", "missing"])
    func humanReviewIsNeverHeld(scenario: String) throws {
        let flow = try ReviewWaitsFixture.flow(agentReview: false)
        var pr = ReviewWaitsFixture.pr()
        if scenario == "pending" { pr.checks = [CheckResult(name: "gate", state: .pending)] }
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.owner == pr.author)
        #expect(!move.hasDispatch)
        #expect(move.pendingChecks == [])
        #expect(move.redChecks == [])
    }

    @Test(arguments: ["pending", "missing", "red", "green"])
    func mergeKeepsItsChecksGreenSemantics(scenario: String) throws {
        let flow = try ReviewWaitsFixture.flow()
        var pr = ReviewWaitsFixture.pr()
        pr.comments = [ReviewWaitsFixture.review("approve")]
        switch scenario {
        case "pending": pr.checks = [CheckResult(name: "gate", state: .pending)]
        case "red": pr.checks = [CheckResult(name: "gate", state: .failure)]
        case "green": pr.checks = [CheckResult(name: "gate", state: .success)]
        default: pr.checks = []
        }
        let result = FlowEngine.move(for: pr, flow: flow)
        if scenario == "pending" || scenario == "missing" {
            #expect(result == nil)
        } else {
            let move = try #require(result)
            #expect(move.name == "merge")
            #expect(move.owner == pr.author)
            #expect(move.hasDispatch == (scenario == "green"))
            #expect(move.redChecks == (scenario == "red" ? ["gate"] : []))
            #expect(move.pendingChecks == [])
        }
    }

    @Test func fixDispatchIsNotHeldByPendingChecks() throws {
        let flow = try ReviewWaitsFixture.flow(includeFix: true)
        var pr = ReviewWaitsFixture.pr()
        pr.comments = [ReviewWaitsFixture.review("changes")]
        pr.checks = [CheckResult(name: "gate", state: .pending)]
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "fix")
        #expect(move.owner == pr.author)
        #expect(move.hasDispatch)
        #expect(move.pendingChecks == [])
        #expect(move.redChecks == [])
        #expect(FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: pr.author))
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo)
        #expect(candidates.count == 1)
        #expect(candidates.first?.move.name == "fix")
    }

    @Test(arguments: ["complete", "pending", "missing", "none known"])
    func truncatedChecksAreJudgedOnlyByWhatIsKnown(scenario: String) throws {
        let flow = try ReviewWaitsFixture.flow(includeMerge: scenario != "none known")
        var pr = ReviewWaitsFixture.pr()
        pr.checksTruncated = true
        switch scenario {
        case "complete": pr.checks = [CheckResult(name: "gate", state: .success)]
        case "pending": pr.checks = [CheckResult(name: "gate", state: .pending)]
        default: pr.checks = []
        }
        let held = scenario == "pending" || scenario == "missing"
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.hasDispatch == !held)
        #expect(move.pendingChecks == (held ? ["gate"] : []))
        #expect(move.redChecks == [])
        #expect(FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: pr.author) == !held)
        #expect(DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo).count == (held ? 0 : 1))
    }
}

private enum ReviewWaitsFixture {
    static let head = "d67db2a8" + String(repeating: "a", count: 32)

    static func flow(includeMerge: Bool = true, agentReview: Bool = true, includeFix: Bool = false,
                     mergePredicates: [String] = ["approved_current_head", "checks_green:gate"],
                     extraMoves: [[String: Any]] = [], decorated: Bool = false) throws -> Flow {
        var moves: [[String: Any]] = [["move": "review",
            "when": decorated ? ["no_review_or_response_newer", "label:needs-review"] : ["no_review_or_response_newer"],
            "who": decorated ? "reviewer" : "author"]]
        if includeMerge { moves.append(["move": "merge", "when": mergePredicates, "who": "author"]) }
        if includeFix { moves.append(["move": "fix", "when": ["latest_review_changes_or_blocked"], "who": "author"]) }
        moves += extraMoves
        var dispatch: [String: Any] = ["merge": ["command": ["/usr/bin/true"]]]
        if agentReview { dispatch["review"] = ["agent": "codex", "prompt": "Review PR #{number} at {head}"] }
        if includeFix { dispatch["fix"] = ["agent": "codex", "prompt": "Fix PR #{number} at {head}"] }
        var tier: [String: Any] = ["marker": "Tier:", "values": ["feature"], "default": "feature"]
        var reviews: [String: Any] = ["feature": [["heading": "## Review:", "notByAuthor": true]]]
        if decorated {
            tier["values"] = ["feature", "careful"]
            tier["paths"] = ["careful": ["Sources/**"]]
            reviews["careful"] = [["heading": "## Review:", "notByAuthor": true]]
        }
        var object: [String: Any] = ["version": 1, "base": "main", "tier": tier,
            "reviews": reviews, "fixed": "## Fixed:", "moves": moves, "dispatch": dispatch]
        if decorated { object["reviewers"] = ["reviewer"] }
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// An hour old by default: GitHub has long registered whatever runs on the head.
    static func pr(age: TimeInterval = 3_600) -> PullRequest {
        PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic PR", author: "owner",
            authorAssociation: "MEMBER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: head, headRef: "feature", baseRef: "main", body: "Tier: feature", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: Date(timeIntervalSinceNow: -age))
    }

    static func review(_ verdict: String) -> PullRequestComment {
        PullRequestComment(author: "reviewer", authorAssociation: "MEMBER",
            body: "## Review: \(verdict) (head d67db2a8)",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
}
