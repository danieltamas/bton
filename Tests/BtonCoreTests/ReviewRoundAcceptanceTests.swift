import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct ReviewRoundAcceptanceTests {
    @Test func jobKeyDefaultsDescriptionIdentityAndJSONCompatibility() throws {
        let legacy = JobKey(repo: "synthetic/project", item: "pr-582", move: "decide", head: RoundFixture.head)
        let key = JobKey(repo: legacy.repo, item: legacy.item, move: legacy.move, head: legacy.head, round: "1761774000")
        #expect(legacy.round == "")
        #expect(legacy.description == "synthetic/project#pr-582 decide@abcdef12aaaa")
        #expect(key.description == "synthetic/project#pr-582 decide@abcdef12aaaa/1761774000")
        #expect(key != legacy)
        #expect(Set([legacy, key]).count == 2)
        let json = #"{"repo":"synthetic/project","item":"pr-582","move":"decide","head":"abcdef12aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
        let decoded = try JSONDecoder().decode(JobKey.self, from: Data(json.utf8))
        #expect(decoded.round == "")
        #expect(decoded == legacy)
        let restored = try JSONDecoder().decode(JobKey.self, from: JSONEncoder().encode(key))
        #expect(restored.round == "1761774000")
        #expect(restored == key)
    }

    @Test func roundTracksNewestTrustedReviewBySomeoneElse() throws {
        let flow = try RoundFixture.flow()
        var pr = RoundFixture.pr()
        #expect(FlowEngine.round(of: pr, flow: flow, me: "dani") == "")
        pr.comments = [RoundFixture.comment(at: RoundFixture.t1, association: "NONE")]
        #expect(FlowEngine.round(of: pr, flow: flow, me: "dani") == "")
        pr.comments = [RoundFixture.comment(at: RoundFixture.t1)]
        #expect(FlowEngine.round(of: pr, flow: flow, me: "dani") == "1761774000")
        pr.comments.append(RoundFixture.comment("## Decision: approve", author: "DaNi", at: RoundFixture.t1.addingTimeInterval(60)))
        #expect(FlowEngine.reviews(of: pr, flow: flow).count == 2)
        #expect(FlowEngine.round(of: pr, flow: flow, me: "dani") == "1761774000")
        pr.comments.insert(RoundFixture.comment(at: RoundFixture.t2), at: 0)
        #expect(FlowEngine.round(of: pr, flow: flow, me: "dani") == "1761774120")
        var otherPR = RoundFixture.pr(author: "someone-else")
        otherPR.comments = pr.comments + [RoundFixture.comment(author: "DANI", at: RoundFixture.t2.addingTimeInterval(60))]
        #expect(FlowEngine.reviews(of: otherPR, flow: flow).count == 4)
        #expect(FlowEngine.round(of: otherPR, flow: flow, me: "dani") == "1761774120")
    }

    @Test func issue582NewReviewOnSameHeadOffersAnotherDecideRun() throws {
        let flow = try RoundFixture.flow()
        var pr = RoundFixture.pr()
        pr.comments = [RoundFixture.comment(at: RoundFixture.t1)]
        let firstCandidates = DispatchPlanner.candidates([pr], flow: flow, me: "dani", repo: pr.repo)
        #expect(firstCandidates.count == 1)
        let first = try #require(firstCandidates.first)
        #expect(first.move.name == "decide")
        #expect(first.move.owner == "dani")
        #expect(first.key.round == "1761774000")
        let jobs = [Job(id: UUID(), key: first.key, agent: "claude", startedAt: RoundFixture.t1, status: .succeeded)]
        #expect(!DispatchPlanner.offersStart("decide", current: "decide", startsMoves: false,
            ranOnHead: jobs.contains { $0.key == first.key }, failedOnHead: false))
        pr.comments.append(RoundFixture.comment("## Decision: approve", author: "dani", at: RoundFixture.t1.addingTimeInterval(60)))
        pr.comments.append(RoundFixture.comment(at: RoundFixture.t2))
        let nextCandidates = DispatchPlanner.candidates([pr], flow: flow, me: "dani", repo: pr.repo)
        #expect(nextCandidates.count == 1)
        let next = try #require(nextCandidates.first)
        #expect(next.move.name == "decide")
        #expect(next.key.head == first.key.head)
        #expect(next.key.round == "1761774120")
        #expect(next.key != jobs[0].key)
        #expect(DispatchPlanner.offersStart("decide", current: "decide", startsMoves: false,
            ranOnHead: jobs.contains { $0.key == next.key }, failedOnHead: false))
    }

    @Test func plannerKeyMatchesCandidateKey() throws {
        let flow = try RoundFixture.flow()
        var pr = RoundFixture.pr()
        pr.comments = [RoundFixture.comment(at: RoundFixture.t1)]
        let candidate = try #require(DispatchPlanner.candidates([pr], flow: flow, me: "dani", repo: pr.repo).first)
        let key = DispatchPlanner.key(for: pr, move: candidate.move.name, flow: flow, me: "dani", repo: pr.repo)
        #expect(key == candidate.key)
        #expect(key == JobKey(repo: pr.repo, item: "pr-582", move: "decide", head: pr.headSha, round: "1761774000"))
    }
}

private enum RoundFixture {
    static let head = "abcdef12" + String(repeating: "a", count: 32)
    static let t1 = Date(timeIntervalSince1970: 1_761_774_000)
    static let t2 = Date(timeIntervalSince1970: 1_761_774_120)

    static func flow() throws -> Flow {
        let json: [String: Any] = [
            "version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:", "notByAuthor": true]]],
            "fixed": "## Fixed:",
            "decision": ["heading": "## Decision:", "move": "decide", "by": ["dani"]],
            "moves": [["move": "decide", "when": ["latest_review_changes_or_blocked"], "who": "author"]],
            "dispatch": ["decide": ["agent": "claude", "prompt": "Decide PR {number}."]]
        ]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func comment(_ heading: String = "## Review: changes", author: String = "vlad",
                        at: Date, association: String = "MEMBER") -> PullRequestComment {
        PullRequestComment(author: author, authorAssociation: association,
            body: "\(heading) (head abcdef12)\nSynthetic findings.", createdAt: at)
    }

    static func pr(author: String = "dani") -> PullRequest {
        PullRequest(repo: "synthetic/project", number: 582, title: "Synthetic PR", author: author,
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/582")!,
            headSha: head, headRef: "feature", baseRef: "main", body: "Tier: feature", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: t1)
    }
}
