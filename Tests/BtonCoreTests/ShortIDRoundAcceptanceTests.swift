@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct ShortIDRoundAcceptanceTests {
    private typealias F = FullReviewIDFixture

    @Test(arguments: 1...13)
    func onlyMyShortHeadApprovalGetsOneExtraReviewRound(scenario: Int) throws {
        let flow = try F.flow(rounds: true)
        var pr = F.pr([F.comment(String(F.head.prefix(8)))])
        var move = "review", me = "me", expected = "+short-id", again = true
        switch scenario {
        case 2:
            pr.comments = [F.comment(F.head, verdict: "changes", author: "teammate"),
                           F.comment(String(F.head.prefix(8)), second: 1)]
            expected = "1800000000+short-id"
        case 3, 4:
            pr.comments.append(F.comment(String(F.head.prefix(scenario == 3 ? 8 : 12)), second: 1))
        case 5: pr.labels = ["turn:lead"]; move = "decide"; again = false; expected = ""
        case 6: move = "merge"; again = false; expected = ""
        case 7:
            pr.comments = [F.comment(String(F.head.prefix(8)), author: "teammate")]
            again = false; expected = "1800000000"
        case 8: pr.comments = [F.comment(F.head)]; again = false; expected = ""
        case 9: pr.comments = [F.comment(String(F.other.prefix(8)))]; again = false; expected = ""
        case 10:
            pr.comments = [F.comment(String(F.head.prefix(8)), verdict: "changes")]
            again = false; expected = ""
        case 11:
            pr.carriedHeads = [F.carried]
            pr.comments = [F.comment(String(F.carried.prefix(8)))]; again = false; expected = ""
        case 12: me = "ME"
        case 13: expected = ""
        default: break
        }
        #expect(FlowEngine.reviewsAgain(move, pr: pr, flow: flow, me: me) == again)
        let key = DispatchPlanner.key(for: pr, move: move, flow: scenario == 13 ? nil : flow, me: me, repo: pr.repo)
        #expect(key.round == expected)
        if scenario == 1 { #expect(key.description.hasSuffix("/+short-id")) }
        if scenario == 3 || scenario == 4 {
            let first = F.pr([F.comment(String(F.head.prefix(8)))])
            #expect(key == DispatchPlanner.key(for: first, move: "review", flow: flow, me: "me", repo: pr.repo))
        }
        if scenario == 6 {
            for name in ["merge", "fix", "fix-ci", "absent"] {
                #expect(!FlowEngine.reviewsAgain(name, pr: pr, flow: flow, me: me))
                #expect(DispatchPlanner.key(for: pr, move: name, flow: flow, me: me, repo: pr.repo).round == "")
            }
        }
    }

    @Test(arguments: [14, 15])
    func onlyTheSelectedReviewRuleCanOpenAShortIDRound(scenario: Int) throws {
        let manual: [String: Any] = [
            "move": "review", "when": ["label:manual"], "who": "assignee"]
        let repair: [String: Any] = [
            "move": "review", "when": ["no_review_or_response_newer", "label:absent"],
            "who": "assignee"]
        let json: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": ["small": [["heading": "## Review:", "notByAuthor": true]]],
            "decision": ["heading": "## Decision:", "move": "decide", "by": ["author"]],
            "fixed": "## Fixed:", "moves": scenario == 14 ? [manual, repair] : [repair, manual],
            "dispatch": ["review": ["agent": "synthetic", "prompt": "Review", "post": "comment"]]]
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
        var pr = F.pr([F.comment(String(F.head.prefix(8)))])
        pr.labels = scenario == 14 ? ["manual"] : ["manual", "absent"]

        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "review")
        #expect(FlowEngine.reviewsAgain("review", pr: pr, flow: flow, me: "me") == (scenario == 15))
        let key = DispatchPlanner.key(for: pr, move: "review", flow: flow, me: "me", repo: pr.repo)
        #expect(key.round == (scenario == 14 ? "" : "+short-id"))

        if scenario == 14 {
            let candidates = DispatchPlanner.candidates([pr], flow: flow, me: "me", repo: pr.repo)
            #expect(candidates.count == 1)
            let candidate = try #require(candidates.first)
            #expect(candidate.key.round == "")
            #expect(candidate.key == key)
            let completed = Job(id: UUID(), key: key, agent: "synthetic", startedAt: F.now, status: .succeeded)
            let agents = ["synthetic": AgentTemplate(argv: ["/usr/bin/true"])]
            #expect(DispatchPlanner.select(candidates, jobs: [completed], maxAgents: 1, agents: agents).isEmpty)
        }
    }

    @Test func completedOriginalRunAllowsRepairButCompletedRepairNeverLoops() throws {
        let flow = try F.flow(rounds: true)
        let pr = F.pr([F.comment(String(F.head.prefix(8)))])
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: "me", repo: pr.repo)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        let repaired = JobKey(repo: pr.repo, item: "pr-7", move: "review", head: F.head, round: "+short-id")
        #expect(candidate.move.name == "review")
        #expect(candidate.key == repaired)
        let original = JobKey(repo: pr.repo, item: "pr-7", move: "review", head: F.head)
        let agents = ["synthetic": AgentTemplate(argv: ["/usr/bin/true"])]
        let old = Job(id: UUID(), key: original, agent: "synthetic", startedAt: F.now, status: .succeeded)
        #expect(DispatchPlanner.select(candidates, jobs: [old], maxAgents: 1, agents: agents).map(\.key) == [repaired])
        let repair = Job(id: UUID(), key: repaired, agent: "synthetic", startedAt: F.now, status: .succeeded)
        #expect(DispatchPlanner.select(candidates, jobs: [old, repair], maxAgents: 1, agents: agents).isEmpty)
    }
}
