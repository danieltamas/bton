@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct MoveWaitAcceptanceTests {
    @Test(arguments: ["pending", "absent", "other checks", "green and pending", "ordered", "mixed", "unread"])
    func incompleteChecksExplainTheHoldingRule(state: String) throws {
        let (pr, flow, expected) = try MoveWaitFixture.state(state)
        #expect(FlowEngine.move(for: pr, flow: flow) == nil)
        #expect(FlowEngine.wait(for: pr, flow: flow) == expected)
    }

    @Test(arguments: ["green", "red", "review", "agent review"])
    func aMoveNeverHasAWait(state: String) throws {
        let (pr, flow, _) = try MoveWaitFixture.state(state)
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == (state.contains("review") ? "review" : "merge"))
        if state == "red" { #expect(move.redChecks == ["gate"]); #expect(!move.hasDispatch) }
        if state == "agent review" { #expect(move.pendingChecks == ["gate"]); #expect(!move.hasDispatch) }
        #expect(FlowEngine.wait(for: pr, flow: flow) == nil)
    }

    @Test(arguments: ["no review", "changes", "old approval", "release"])
    func unrelatedPredicatesAndReleaseDoNotWait(state: String) throws {
        let (pr, flow, _) = try MoveWaitFixture.state(state)
        #expect(FlowEngine.wait(for: pr, flow: flow) == nil)
    }

    @Test func firstHoldingRuleWinsInFlowOrder() throws {
        let first = MoveWaitFixture.rule("first", ["approved_current_head", "checks_green:z,a"])
        let second = MoveWaitFixture.rule("second", ["approved_current_head", "checks_green:b"])
        let pr = MoveWaitFixture.pr()
        for (rules, expected) in [([first, second], MoveWait(move: "first", checks: ["z", "a"])),
                                  ([second, first], MoveWait(move: "second", checks: ["b"]))] {
            #expect(FlowEngine.wait(for: pr, flow: try MoveWaitFixture.flow(rules: rules)) == expected)
        }
    }

    @Test(arguments: ["checks_green:", "checks_green:gate,"])
    func malformedCheckPredicateCannotHold(predicate: String) throws {
        let malformed = MoveWaitFixture.rule("bad", ["approved_current_head", predicate])
        let valid = MoveWaitFixture.rule("merge", ["approved_current_head", "checks_green:gate"])
        let pr = MoveWaitFixture.pr()
        #expect(FlowEngine.wait(for: pr, flow: try MoveWaitFixture.flow(rules: [malformed])) == nil)
        #expect(FlowEngine.wait(for: pr, flow: try MoveWaitFixture.flow(rules: [malformed, valid]))
            == MoveWait(move: "merge", checks: ["gate"]))
    }

    @Test(arguments: ["green", "pending", "absent", "unread"],
          ["checks_green:", "checks_green:a,", "checks_green:,a"])
    func mixedMalformedCheckPredicateCannotHold(state: String, predicate: String) throws {
        var pr = MoveWaitFixture.pr()
        pr.checks = state == "absent" ? [] : [.init(name: "gate", state: state == "pending" ? .pending : .success)]
        pr.checks.append(.init(name: "a", state: .success))
        pr.checksTruncated = state == "unread"
        let flow = try MoveWaitFixture.flow(rules: [MoveWaitFixture.rule("merge",
            ["approved_current_head", "checks_green:gate", predicate])])
        #expect(FlowEngine.move(for: pr, flow: flow) == nil)
        #expect(FlowEngine.wait(for: pr, flow: flow) == nil)
    }

    @Test(arguments: [false, true], ["checks_green:", "checks_green:a,", "checks_green:,a"])
    func mixedMalformedRuleDoesNotHideLaterWait(unread: Bool, predicate: String) throws {
        var pr = MoveWaitFixture.pr()
        pr.checks = [.init(name: "gate", state: .success), .init(name: "a", state: .success),
                     .init(name: "e2e", state: .pending)]
        pr.checksTruncated = unread
        let flow = try MoveWaitFixture.flow(rules: [
            MoveWaitFixture.rule("merge", ["approved_current_head", "checks_green:gate", predicate]),
            MoveWaitFixture.rule("ship", ["approved_current_head", "checks_green:e2e"])])
        #expect(FlowEngine.move(for: pr, flow: flow) == nil)
        #expect(FlowEngine.wait(for: pr, flow: flow) == (unread
            ? MoveWait(move: "ship", checksUnread: true) : MoveWait(move: "ship", checks: ["e2e"])))
    }

    @Test func summariesNamePendingRedAndUnreadChecks() {
        #expect(MoveWait(move: "merge", checks: ["gate"]).summary == "merge waits for gate")
        #expect(MoveWait(move: "merge", checks: ["e2e"], redChecks: ["gate"]).summary == "merge waits for e2e (gate red)")
        #expect(MoveWait(move: "merge", checksUnread: true).summary
            == "merge waits for a person: the head has more checks than Bton reads")
        #expect(MoveWait(move: "fix", checks: ["z", "a"], redChecks: ["b", "c"]).summary
            == "fix waits for z, a (b, c red)")
    }

    @Test(arguments: ["pending", "absent", "other checks", "green and pending", "ordered", "mixed", "unread",
                      "green", "red", "review", "agent review", "no review", "changes", "old approval", "release"])
    func judgedReplacesStaleFieldsWithoutChangingMoves(state: String) throws {
        var (pr, flow, expected) = try MoveWaitFixture.state(state)
        let move = FlowEngine.move(for: pr, flow: flow)
        pr.move = Move(name: "obsolete", owner: "someone", ownerFromRotation: false, tier: "small", hasDispatch: true)
        pr.waiting = MoveWait(move: "obsolete", checks: ["old"])
        let judged = FlowEngine.judged(pr, flow: flow)
        #expect(judged.move == move)
        #expect(judged.waiting == expected)
        #expect(judged.waiting == FlowEngine.wait(for: pr, flow: flow))
        var expectedPR = pr
        expectedPR.move = move
        expectedPR.waiting = expected
        #expect(judged == expectedPR)
        expectedPR.move = nil
        expectedPR.waiting = nil
        #expect(FlowEngine.judged(pr, flow: nil) == expectedPR)
    }

    @Test(arguments: ["pending", "absent", "mixed", "unread"])
    func waitingCannotDispatchMergeOrBecomeStale(state: String) throws {
        let (pr, flow, _) = try MoveWaitFixture.state(state)
        let judged = FlowEngine.judged(pr, flow: flow)
        #expect(judged.waiting != nil)
        #expect(DispatchPlanner.candidates([judged], flow: flow, me: "owner", repo: pr.repo).isEmpty)
        #expect(DispatchPlanner.mergeCandidate(judged, flow: flow, me: "owner", repo: pr.repo) == nil)
        #expect(Staleness.notice(for: judged, stale: try #require(flow.stale),
            now: MoveWaitFixture.now.addingTimeInterval(864_000)) == nil)
    }

    @Test func engineLogsWaitOncePerHeadAndWritesNothingToGitHub() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        try f.prepareMerge(checks: "gate")
        try f.editFlow { $0["stale"] = ["pingHours": 1, "escalateHours": 2, "escalateTo": "lead"] }
        let gh = f.root.appendingPathComponent("gh")
        let script = try String(contentsOf: gh, encoding: .utf8)
        let writes = f.root.appendingPathComponent("github-writes")
        let observer = #"""
        case "$*" in
          *' comment '*|*' edit '*|*' --method POST '*|*' --method PATCH '*|*'mutation'*)
            printf '%s\n' "$*" >> "${0%/*}/github-writes" ;;
        esac
        """#
        try script.replacingOccurrences(of: "set -eu", with: "set -eu\n" + observer)
            .write(to: gh, atomically: true, encoding: .utf8)
        let log = MoveLog()
        let engine = try f.engine(log: { log.append($0) })
        let line = "synthetic/project#7: merge waits for gate"
        for _ in 0..<2 {
            let snapshot = await engine.tick()
            #expect(snapshot.problem == nil)
            #expect(snapshot.jobs.isEmpty)
            #expect(snapshot.next.isEmpty)
            #expect(snapshot.openPullRequests.first?.waiting == MoveWait(move: "merge", checks: ["gate"]))
        }
        #expect(log.all.filter { $0 == line }.count == 1)
        try f.updatePRs(head: "abcdef02")
        try f.reviews(["approve"])
        for _ in 0..<2 {
            let snapshot = await engine.tick()
            #expect(snapshot.problem == nil)
            #expect(snapshot.jobs.isEmpty)
            #expect(snapshot.openPullRequests.first?.headSha == "abcdef02")
            #expect(snapshot.openPullRequests.first?.waiting == MoveWait(move: "merge", checks: ["gate"]))
        }
        #expect(log.all.filter { $0 == line }.count == 2)
        #expect(!FileManager.default.fileExists(atPath: writes.path))
    }
}

enum MoveWaitFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let head = "abcdef01" + String(repeating: "a", count: 32)
    static func rule(_ move: String, _ predicates: [String], who: String = "author") -> [String: Any] {
        ["move": move, "when": predicates, "who": who]
    }
    static func flow(checks: String = "gate", rules: [[String: Any]]? = nil, agentReview: Bool = false) throws -> Flow {
        var dispatch: [String: Any] = ["merge": ["command": ["/usr/bin/true"]]]
        if agentReview { dispatch["review"] = ["agent": "synthetic", "prompt": "Review"] }
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": ["small": [["heading": "## Review:", "notByAuthor": true]]], "fixed": "Fixed:",
            "moves": rules ?? [rule("review", ["no_review_or_response_newer"], who: "reviewer"),
                                rule("merge", ["approved_current_head", "checks_green:\(checks)"])],
            "dispatch": dispatch, "stale": ["pingHours": 1, "escalateHours": 2, "escalateTo": "lead"],
            "release": ["from": "release", "to": "main", "who": "owner", "when": ["features_waiting:1"]]]
        // Decode directly so malformed predicates reach wait's fail-closed boundary.
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func pr(verdict: String? = "approve", reviewedHead: String = head, release: Bool = false) -> PullRequest {
        var pr = PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!, headSha: head,
            headRef: release ? "release" : "feature", baseRef: "main", body: "", isDraft: false,
            labels: [], assignees: [], comments: verdict.map { [PullRequestComment(author: "reviewer",
                authorAssociation: "MEMBER", body: "## Review: \($0) (head \(reviewedHead))", createdAt: now)] } ?? [],
            updatedAt: now)
        pr.mergeable = true
        pr.headCommittedAt = now.addingTimeInterval(-3600)
        pr.requestedReviewers = ["teammate"]
        return pr
    }
    static func state(_ name: String) throws -> (PullRequest, Flow, MoveWait?) {
        var pr = pr()
        var flow = try flow()
        var wait: MoveWait? = nil
        switch name {
        case "pending": pr.checks = [.init(name: "gate", state: .pending)]; wait = MoveWait(move: "merge", checks: ["gate"])
        case "absent": wait = MoveWait(move: "merge", checks: ["gate"])
        case "other checks": pr.checks = [.init(name: "other", state: .success)]; wait = MoveWait(move: "merge", checks: ["gate"])
        case "green and pending", "mixed", "ordered":
            flow = try self.flow(checks: "gate,e2e")
            pr.checks = [.init(name: "e2e", state: .pending)]
            if name != "ordered" { pr.checks.append(.init(name: "gate", state: name == "mixed" ? .failure : .success)) }
            wait = MoveWait(move: "merge", checks: name == "ordered" ? ["gate", "e2e"] : ["e2e"],
                            redChecks: name == "mixed" ? ["gate"] : [])
        case "unread": pr.checks = [.init(name: "gate", state: .success)]; pr.checksTruncated = true
            wait = MoveWait(move: "merge", checksUnread: true)
        case "green", "red": pr.checks = [.init(name: "gate", state: name == "green" ? .success : .failure)]
        case "review": pr.comments = []
        case "no review":
            pr.comments = []
            flow = try self.flow(rules: [rule("merge", ["approved_current_head", "checks_green:gate"])])
        case "agent review": pr.comments = []; pr.checks = [.init(name: "gate", state: .pending)]; flow = try self.flow(agentReview: true)
        case "changes", "old approval":
            pr = name == "changes" ? self.pr(verdict: "changes") : self.pr(reviewedHead: "bbbbbbb")
            flow = try self.flow(rules: [rule("merge", ["approved_current_head", "checks_green:gate"])])
        case "release": pr = self.pr(release: true)
        default: Issue.record("Unknown wait state \(name)")
        }
        return (pr, flow, wait)
    }
}
