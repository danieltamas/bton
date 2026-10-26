import BtonCore
import Foundation
import Testing

private enum StalenessFixture {
    static let head = "abcdef123456" + String(repeating: "a", count: 28)
    static let newHead = "fedcba654321" + String(repeating: "b", count: 28)
    static let owner = "synthetic-owner"
    static let viewer = "synthetic-viewer"
    static let escalationOwner = "synthetic-escalation"
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ hours: Double) -> Date { epoch.addingTimeInterval(hours * 3600) }

    static func stale() throws -> Stale {
        try JSONDecoder().decode(Stale.self, from: Data("""
        {"pingHours":24,"escalateHours":48,"escalateTo":"synthetic-escalation"}
        """.utf8))
    }

    static func flow() throws -> Flow {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("examples/sandbox.flow.json"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Keep the example's rules, with only synthetic identities in the decoded fixture.
        json["stale"] = ["pingHours": 24, "escalateHours": 48, "escalateTo": escalationOwner]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func comment(_ body: String, at hours: Double, author: String = viewer) -> [String: Any] {
        ["author": ["login": author], "body": body,
         "createdAt": ISO8601DateFormatter().string(from: at(hours))]
    }

    // Every tick crosses the public GraphQL decoder, including comments posted on prior ticks.
    static func pr(head: String = head, committedAt: Double? = 0,
                   comments: [[String: Any]] = [], withMove: Bool = true) throws -> PullRequest {
        var node: [String: Any] = [
            "number": 17, "title": "Synthetic staleness fixture",
            "url": "https://github.com/synthetic/project/pull/17", "isDraft": false,
            "headRefOid": head, "headRefName": "feature/synthetic", "baseRefName": "main",
            "body": "Synthetic change for acceptance testing.",
            "updatedAt": ISO8601DateFormatter().string(from: at(100)),
            "authorAssociation": "OWNER", "author": ["login": owner],
            "labels": ["nodes": []], "assignees": ["nodes": []],
            "comments": ["nodes": comments]
        ]
        if let committedAt {
            node["commits"] = ["nodes": [["commit": [
                "committedDate": ISO8601DateFormatter().string(from: at(committedAt))
            ]]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["data": [
            "viewer": ["login": viewer], "repository": ["defaultBranchRef": ["name": "main"],
            "pullRequests": ["nodes": [node]]]
        ]])
        var pr = try #require(GitHubClient.decodeOpenPullRequests(data, repo: "synthetic/project")
            .pullRequests.first)
        if withMove { pr.move = FlowEngine.move(for: pr, flow: try flow()) }
        return pr
    }
}

@Suite(ProcessBound())
struct StalenessAcceptanceTests {
    @Test func pingStartsAfterThresholdAndNamesOwnerMoveAndHead() throws {
        let pr = try StalenessFixture.pr(comments: [
            StalenessFixture.comment("Earlier human context.", at: -1, author: "synthetic-human")
        ])
        let stale = try StalenessFixture.stale()
        let move = try #require(pr.move)
        #expect(move.owner == StalenessFixture.owner)
        #expect(pr.headCommittedAt == StalenessFixture.at(0))
        #expect(Staleness.since(pr) == StalenessFixture.at(0))
        #expect(Staleness.notice(for: pr, stale: stale, now: StalenessFixture.at(23.99)) == nil)
        let ping = try #require(Staleness.notice(for: pr, stale: stale, now: StalenessFixture.at(24.01)))
        #expect(ping.body.contains("@\(StalenessFixture.owner)"))
        #expect(!ping.body.contains("@\(StalenessFixture.escalationOwner)"))
        #expect(ping.marker.contains(move.name))
        #expect(ping.marker.contains(String(pr.headSha.prefix(12))))
        #expect(ping.body.hasSuffix("<!-- bton:\(ping.marker) -->"))
    }

    @Test func threeTicksProduceOnePingWithoutRestartingClock() throws {
        let stale = try StalenessFixture.stale()
        let first = try StalenessFixture.pr()
        let ping = try #require(Staleness.notice(for: first, stale: stale, now: StalenessFixture.at(25)))
        let posted = StalenessFixture.comment(ping.body, at: 25)
        for hour in [30.0, 47.0] {
            let next = try StalenessFixture.pr(comments: [posted])
            #expect(next.comments.isEmpty)
            #expect(next.btonMarkers.contains(ping.marker))
            #expect(next.move == first.move)
            #expect(Staleness.since(next) == StalenessFixture.at(0))
            #expect(Staleness.notice(for: next, stale: stale, now: StalenessFixture.at(hour)) == nil)
        }
    }

    @Test func escalationMentionsBothOwnersAndIsDeduplicatedAfterPosting() throws {
        let stale = try StalenessFixture.stale()
        let pr = try StalenessFixture.pr()
        let ping = try #require(Staleness.notice(for: pr, stale: stale, now: StalenessFixture.at(25)))
        let pingComment = StalenessFixture.comment(ping.body, at: 25)
        let waiting = try StalenessFixture.pr(comments: [pingComment])
        let escalation = try #require(Staleness.notice(for: waiting, stale: stale, now: StalenessFixture.at(49)))
        #expect(escalation.body.contains("@\(StalenessFixture.escalationOwner)"))
        #expect(escalation.body.contains("@\(StalenessFixture.owner)"))
        #expect(escalation.marker != ping.marker)
        #expect(escalation.body.hasSuffix("<!-- bton:\(escalation.marker) -->"))
        let posted = try StalenessFixture.pr(comments: [
            pingComment, StalenessFixture.comment(escalation.body, at: 49)
        ])
        #expect(posted.comments.isEmpty)
        #expect(posted.btonMarkers.contains(escalation.marker))
        #expect(Staleness.since(posted) == StalenessFixture.at(0))
        #expect(Staleness.notice(for: posted, stale: stale, now: StalenessFixture.at(72)) == nil)
    }

    @Test func missedPingProducesOnlyEscalation() throws {
        let stale = try StalenessFixture.stale()
        let pr = try StalenessFixture.pr()
        let escalation = try #require(Staleness.notice(for: pr, stale: stale, now: StalenessFixture.at(49)))
        #expect(escalation.body.contains("@\(StalenessFixture.escalationOwner)"))
        #expect(escalation.body.contains("@\(StalenessFixture.owner)"))
        let posted = try StalenessFixture.pr(comments: [StalenessFixture.comment(escalation.body, at: 49)])
        #expect(posted.btonMarkers == Set([escalation.marker]))
        #expect(Staleness.notice(for: posted, stale: stale, now: StalenessFixture.at(50)) == nil)
    }

    @Test func newHeadResetsClockAndGetsDistinctPingMarker() throws {
        let stale = try StalenessFixture.stale()
        let old = try StalenessFixture.pr()
        let oldPing = try #require(Staleness.notice(for: old, stale: stale, now: StalenessFixture.at(25)))
        let new = try StalenessFixture.pr(head: StalenessFixture.newHead, committedAt: 30,
            comments: [StalenessFixture.comment(oldPing.body, at: 25)])
        #expect(new.move == old.move)
        #expect(new.btonMarkers.contains(oldPing.marker))
        #expect(Staleness.since(new) == StalenessFixture.at(30))
        #expect(Staleness.notice(for: new, stale: stale, now: StalenessFixture.at(31)) == nil)
        let newPing = try #require(Staleness.notice(for: new, stale: stale, now: StalenessFixture.at(54.01)))
        #expect(newPing.marker != oldPing.marker)
        #expect(newPing.marker.contains(String(StalenessFixture.newHead.prefix(12))))
        #expect(newPing.body.contains("@\(StalenessFixture.owner)"))
    }

    @Test func laterHumanCommentRestartsClock() throws {
        let pr = try StalenessFixture.pr(comments: [
            StalenessFixture.comment("Synthetic human update.", at: 20, author: "synthetic-human")
        ])
        let stale = try StalenessFixture.stale()
        #expect(Staleness.since(pr) == StalenessFixture.at(20))
        #expect(Staleness.notice(for: pr, stale: stale, now: StalenessFixture.at(25)) == nil)
        #expect(Staleness.notice(for: pr, stale: stale, now: StalenessFixture.at(44.01)) != nil)
    }

    @Test func noMoveProducesNoNotice() throws {
        let pr = try StalenessFixture.pr(withMove: false)
        #expect(pr.move == nil)
        #expect(Staleness.notice(for: pr, stale: try StalenessFixture.stale(),
            now: StalenessFixture.at(100)) == nil)
    }

    @Test func missingCommitsFallsBackToLastCommentAndMissingBothProducesNoNotice() throws {
        let stale = try StalenessFixture.stale()
        let pr = try StalenessFixture.pr(committedAt: nil, comments: [
            StalenessFixture.comment("Latest human context.", at: 10, author: "synthetic-human"),
            StalenessFixture.comment("Earlier human context.", at: 0, author: "synthetic-human")
        ])
        #expect(pr.headCommittedAt == nil)
        #expect(Staleness.since(pr) == StalenessFixture.at(10))
        #expect(Staleness.notice(for: pr, stale: stale, now: StalenessFixture.at(33.99)) == nil)
        #expect(Staleness.notice(for: pr, stale: stale, now: StalenessFixture.at(34.01)) != nil)
        let undated = try StalenessFixture.pr(committedAt: nil)
        #expect(undated.headCommittedAt == nil)
        #expect(Staleness.since(undated) == nil)
        #expect(Staleness.notice(for: undated, stale: stale, now: StalenessFixture.at(100)) == nil)
    }
}
