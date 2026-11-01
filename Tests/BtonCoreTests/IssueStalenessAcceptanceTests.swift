@testable import BtonCore
import Foundation
import Testing

/// The flow's `stale` hours on an issue someone took: its assignees are pinged once per wait, the
/// escalation goes to `escalateTo`, and only a person or a state change restarts the clock.
private enum IssueStalenessFixture {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ hours: Double) -> Date { epoch.addingTimeInterval(hours * 3600) }

    static func stale() throws -> Stale {
        try JSONDecoder().decode(Stale.self, from: Data(#"{"pingHours":24,"escalateHours":48,"escalateTo":"lead"}"#.utf8))
    }

    static func comment(_ id: String, author: String, body: String = "COMMENT_BODY_DATA", hours: Double) -> IssueComment {
        IssueComment(id: id, author: author, authorAssociation: "MEMBER", body: body, createdAt: at(hours), url: nil)
    }

    static func issue(assignees: [String] = ["lee"], comments: [IssueComment] = [], stateChangedAt: Date? = nil,
                      body: String = "ISSUE_BODY_DATA") -> OpenIssue {
        OpenIssue(repo: "synthetic/project", number: 7, title: "ISSUE_TITLE_DATA", url: URL(string: "https://example.invalid/issues/7")!,
                  createdAt: at(0), author: "dani", authorAssociation: "OWNER", body: body, comments: comments,
                  labels: ["stage:in-progress"], assignees: assignees, stateChangedAt: stateChangedAt)
    }
}

struct IssueStalenessAcceptanceTests {
    private typealias F = IssueStalenessFixture

    @Test func anAssignedIssueIsPingedOncePastTheHoursAndEscalatedOncePastTheOthers() throws {
        let stale = try F.stale()
        #expect(Staleness.notice(for: F.issue(), stale: stale, now: F.at(23)) == nil)
        #expect(Staleness.notice(for: F.issue(assignees: []), stale: stale, now: F.at(30)) == nil)
        let ping = try #require(Staleness.notice(for: F.issue(assignees: ["lee", "kim"]), stale: stale, now: F.at(25)))
        #expect(ping.marker == "stale-ping issue@\(Int(F.at(0).timeIntervalSince1970))")
        #expect(ping.body.hasPrefix("@lee @kim: #7 has waited 25 hours"))
        #expect(ping.body.contains(BtonMarker.line(ping.marker)))
        // Posted (the marker is in a comment of mine): not again, and the ping never resets the clock.
        let pinged = F.issue(comments: [F.comment("1", author: "dani", body: ping.body, hours: 25)])
        #expect(Staleness.notice(for: pinged, stale: stale, now: F.at(30)) == nil)
        // Past the escalation only the escalation, also when the ping was never posted.
        let escalation = try #require(Staleness.notice(for: F.issue(), stale: stale, now: F.at(49)))
        #expect(escalation.marker == "stale-escalate issue@\(Int(F.at(0).timeIntervalSince1970))")
        #expect(escalation.body.hasPrefix("@lead: #7 has waited 49 hours"))
        #expect(escalation.body.contains("@lee"))
        let escalated = F.issue(comments: [F.comment("1", author: "dani", body: ping.body, hours: 25),
                                           F.comment("2", author: "dani", body: escalation.body, hours: 49)])
        #expect(Staleness.notice(for: escalated, stale: stale, now: F.at(80)) == nil)
    }

    @Test func aPersonOrAStateChangeStartsANewWaitAndBtonsOwnLinesDoNot() throws {
        let stale = try F.stale()
        // A person's comment at hour 20: at hour 30 the issue has waited 10 hours.
        let spoken = F.issue(comments: [F.comment("1", author: "lee", hours: 20)])
        #expect(Staleness.since(spoken) == F.at(20))
        #expect(Staleness.notice(for: spoken, stale: stale, now: F.at(30)) == nil)
        let later = try #require(Staleness.notice(for: spoken, stale: stale, now: F.at(45)))
        #expect(later.marker == "stale-ping issue@\(Int(F.at(20).timeIntervalSince1970))")
        // An assignment or label change at hour 40 is a new wait too; the triager's line is not.
        #expect(Staleness.since(F.issue(stateChangedAt: F.at(40))) == F.at(40))
        let triaged = F.issue(comments: [F.comment("1", author: "dani", body: "Impact: 1\n\n" + IssueMoves.marker, hours: 40)])
        #expect(Staleness.since(triaged) == F.at(0))
        // The issue read again under the lease, with every comment: the ping posted 25 comments
        // ago is seen, and the newest person's word moves the clock, so the notice is not the same.
        let full = F.issue().with(comments: [F.comment("0", author: "lee", hours: 20)] + (1...25).map { F.comment("\($0)", author: "dani", body: "Impact: 1\n\n" + IssueMoves.marker, hours: 21) })
        #expect(Staleness.since(full) == F.at(20))
        #expect(full.comments.count == 26)
        // The same wait a minute later is the same marker with another hour count in the body:
        // the lease compares markers, so a notice due at the read is still due at the claim.
        let read = try #require(Staleness.notice(for: spoken, stale: stale, now: F.at(44.99)))
        let claim = try #require(Staleness.notice(for: spoken, stale: stale, now: F.at(45.01)))
        #expect(read.marker == claim.marker)
        #expect(read.body != claim.body)
        // An issue waiting on me is my wait, not the assignee's.
        #expect(Staleness.notice(for: F.issue(), stale: stale, askedOfMe: true, now: F.at(30)) == nil)
    }

    @Test func theReadCarriesTheLastAssignmentOrLabelEvent() throws {
        let payload = """
        {"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
          {"number":7,"title":"ISSUE_TITLE_DATA","url":"https://example.invalid/issues/7","createdAt":"2027-01-15T08:00:00Z",
           "body":"ISSUE_BODY_DATA","authorAssociation":"OWNER","author":{"login":"dani"},"labels":{"nodes":[]},
           "assignees":{"nodes":[{"login":"lee"}]},"comments":{"nodes":[]},
           "timelineItems":{"nodes":[{"createdAt":"2027-01-16T09:30:00Z"}]}},
          {"number":8,"title":"ISSUE_TITLE_DATA","url":"https://example.invalid/issues/8","createdAt":"2027-01-15T08:00:00Z",
           "body":"ISSUE_BODY_DATA","authorAssociation":"OWNER","author":{"login":"dani"},"labels":{"nodes":[]},
           "assignees":{"nodes":[]},"comments":{"nodes":[]},"timelineItems":{"nodes":[{}]}}
        ]}}}}
        """
        let issues = try GitHubClient.decodeOpenIssues(Data(payload.utf8), repo: "synthetic/project").issues
        #expect(issues.first?.stateChangedAt == ISO8601DateFormatter().date(from: "2027-01-16T09:30:00Z"))
        #expect(issues.last?.stateChangedAt == nil)
    }
}
