@testable import BtonCore
import Foundation
import Testing

private enum ScheduleQueueChangeFixture {
    static let repo = "acme/widget"
    static let now = Date(timeIntervalSince1970: 120_030)
    static let old = now.addingTimeInterval(-3600)
    static let firstStart = now.addingTimeInterval(-1800)
    static let change = now.addingTimeInterval(-1500)
    static let laterStart = now.addingTimeInterval(-900)

    static func pr(number: Int = 1, updatedAt: Date = now, createdAt: Date? = old,
                   headCommittedAt: Date? = old, headSha: String = "abc123", comments: [PullRequestComment] = []) -> PullRequest {
        var pr = PullRequest(repo: repo, number: number, title: "Synthetic widget", author: "octo",
                             authorAssociation: "OWNER", url: URL(string: "https://example.com/pr/\(number)")!,
                             headSha: headSha, headRef: "feature", baseRef: "main", body: "",
                             isDraft: false, labels: [], assignees: [], comments: comments, updatedAt: updatedAt)
        pr.createdAt = createdAt
        pr.headCommittedAt = headCommittedAt
        return pr
    }

    static func comment(at date: Date) -> PullRequestComment {
        PullRequestComment(author: "octo", body: "Please check the widget.", createdAt: date)
    }

    static func job(startedAt: Date, queueHeads: [String]? = nil) -> Job {
        var job = Job(id: UUID(), key: JobKey(repo: repo, item: "schedule-7", move: "schedule", head: "old-minute"),
            agent: "codex", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60), status: .succeeded)
        job.queueHeads = queueHeads
        return job
    }

    static func candidates(changedAt: Date?, pushedAt: Date? = nil, jobs: [Job], queueHeads: [String] = []) -> [DispatchCandidate] {
        var entry = ScheduleEntry(name: "Daily check", everyMinutes: 10, enabled: true,
                                  repo: repo, agent: "codex", prompt: "Inspect the synthetic widget.", number: 7)
        entry.onlyOnChange = true
        return DispatchPlanner.scheduled([entry], jobs: jobs, repo: repo, defaultBranch: "main",
                                         me: "octo", now: now, changedAt: changedAt, pushedAt: pushedAt, queueHeads: queueHeads)
    }
}

@Suite(ProcessBound())
struct ScheduleQueueChangeAcceptanceTests {
    private typealias F = ScheduleQueueChangeFixture
    @Test func labelFlipDoesNotRearmSchedule() {
        let pr = F.pr(updatedAt: F.now, comments: [F.comment(at: F.old)])
        let changedAt = DispatchPlanner.queueChangedAt([pr], merged: [])
        #expect(pr.updatedAt > F.firstStart)
        #expect(changedAt == F.old)
        #expect(F.old < F.firstStart)
        #expect(F.candidates(changedAt: changedAt, jobs: [F.job(startedAt: F.firstStart)]).isEmpty)
    }
    @Test func newCommentMakesExactlyOneRunDue() {
        let pr = F.pr(comments: [F.comment(at: F.old), F.comment(at: F.change)])
        let changedAt = DispatchPlanner.queueChangedAt([pr], merged: [])
        #expect(changedAt == F.change)
        let first = F.job(startedAt: F.firstStart)
        #expect(F.candidates(changedAt: changedAt, jobs: [first]).count == 1)
        #expect(F.candidates(changedAt: changedAt, jobs: [first, F.job(startedAt: F.laterStart)]).isEmpty)
    }
    @Test func newHeadCommitMakesExactlyOneRunDue() {
        let prs = [F.pr(headCommittedAt: F.change)]
        let changedAt = DispatchPlanner.queueChangedAt(prs, merged: [])
        let pushedAt = DispatchPlanner.queuePushedAt(prs)
        let heads = DispatchPlanner.queueHeads(prs)
        #expect(changedAt == F.old)
        #expect(pushedAt == F.change)
        let first = F.job(startedAt: F.firstStart, queueHeads: heads)
        #expect(F.candidates(changedAt: changedAt, pushedAt: pushedAt, jobs: [first], queueHeads: heads).isEmpty)
        let moved = ["1@new-sha"]
        #expect(F.candidates(changedAt: changedAt, pushedAt: pushedAt, jobs: [first], queueHeads: moved).count == 1)
        let next = F.job(startedAt: F.laterStart, queueHeads: moved)
        #expect(F.candidates(changedAt: changedAt, pushedAt: pushedAt, jobs: [first, next], queueHeads: moved).isEmpty)
    }
    @Test func mergedPullRequestMakesRunDue() {
        let merged = MergedPullRequest(repo: F.repo, number: 2, title: "Merged widget", author: "octo",
                                      url: URL(string: "https://example.com/pr/2")!, mergedAt: F.change)
        let changedAt = DispatchPlanner.queueChangedAt([F.pr()], merged: [merged])
        #expect(changedAt == F.change)
        #expect(F.candidates(changedAt: changedAt, jobs: [F.job(startedAt: F.firstStart)]).count == 1)
    }
    @Test func newlyOpenedPullRequestWithOldHeadMakesRunDue() {
        let changedAt = DispatchPlanner.queueChangedAt([F.pr(createdAt: F.change)], merged: [])
        #expect(changedAt == F.change)
        #expect(F.candidates(changedAt: changedAt, jobs: [F.job(startedAt: F.firstStart)]).count == 1)
    }
    @Test func emptyQueueNeedsNoChangeForFirstRunButDoesNotRearmSuccess() {
        let changedAt = DispatchPlanner.queueChangedAt([], merged: [])
        #expect(changedAt == nil)
        #expect(F.candidates(changedAt: changedAt, jobs: [F.job(startedAt: F.firstStart)]).isEmpty)
        #expect(F.candidates(changedAt: changedAt, jobs: []).count == 1)
    }
    @Test func updatedAtDoesNotAffectQueueChangeTimestamp() {
        let before = F.pr(updatedAt: F.old, comments: [F.comment(at: F.change)])
        let after = F.pr(updatedAt: F.now, comments: [F.comment(at: F.change)])
        #expect(DispatchPlanner.queueChangedAt([before], merged: []) == F.change)
        #expect(DispatchPlanner.queueChangedAt([after], merged: []) == F.change)
        #expect(DispatchPlanner.queueChangedAt([before], merged: [])
                == DispatchPlanner.queueChangedAt([after], merged: []))
    }

    @Test func unknownCreationAndHeadWithoutCommentsHaveNoChangeTimestamp() {
        let pr = F.pr(createdAt: nil, headCommittedAt: nil)
        let changedAt = DispatchPlanner.queueChangedAt([pr], merged: [])
        #expect(changedAt == nil)
        #expect(F.candidates(changedAt: changedAt, jobs: [F.job(startedAt: F.firstStart)]).isEmpty)
    }

    @Test func latestTimestampWinsAcrossPullRequestsAndMergedPullRequests() {
        let merged = MergedPullRequest(repo: F.repo, number: 3, title: "Merged widget", author: "octo",
                                      url: URL(string: "https://example.com/pr/3")!, mergedAt: F.change)
        let prs = [F.pr(number: 1, createdAt: F.laterStart), F.pr(number: 2, headCommittedAt: F.change)]
        #expect(DispatchPlanner.queueChangedAt(prs, merged: [merged]) == F.laterStart)
        #expect(DispatchPlanner.queueChangedAt(Array(prs.reversed()), merged: [merged]) == F.laterStart)
    }

    @Test func movedHeadWithOldDatesRearmsAndCarriesCurrentHeads() throws {
        let prs = [F.pr(headSha: "new-sha")]
        let heads = DispatchPlanner.queueHeads(prs)
        let changedAt = DispatchPlanner.queueChangedAt(prs, merged: [])
        #expect(changedAt == F.old)
        let jobs = [F.job(startedAt: F.firstStart, queueHeads: ["1@old-sha"])]
        let candidates = F.candidates(changedAt: changedAt, jobs: jobs, queueHeads: heads)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(heads == ["1@new-sha"])
        #expect(candidate.queueHeads == heads)
    }

    @Test func unchangedHeadsAndDatesDoNotRearm() {
        let prs = [F.pr()]
        let heads = DispatchPlanner.queueHeads(prs)
        let jobs = [F.job(startedAt: F.firstStart, queueHeads: heads)]
        #expect(F.candidates(changedAt: DispatchPlanner.queueChangedAt(prs, merged: []),
                             jobs: jobs, queueHeads: heads).isEmpty)
    }

    @Test func legacyJobWithoutHeadsUsesDatesAlone() {
        let legacy = F.job(startedAt: F.firstStart)
        #expect(legacy.queueHeads == nil)
        let heads = DispatchPlanner.queueHeads([F.pr()])
        let olderPush = DispatchPlanner.queuePushedAt([F.pr(headCommittedAt: F.old)])
        let newerPush = DispatchPlanner.queuePushedAt([F.pr(headCommittedAt: F.change)])
        #expect(F.candidates(changedAt: F.old, pushedAt: olderPush, jobs: [legacy], queueHeads: heads).isEmpty)
        #expect(F.candidates(changedAt: F.old, pushedAt: newerPush, jobs: [legacy], queueHeads: heads).count == 1)
        let changedAt = DispatchPlanner.queueChangedAt([F.pr(comments: [F.comment(at: F.change)])], merged: [])
        #expect(changedAt == F.change)
        #expect(F.candidates(changedAt: changedAt, jobs: [legacy], queueHeads: heads).count == 1)
    }

    @Test func closedUnmergedPullRequestRearmsWithOldDates() {
        let remaining = [F.pr(number: 1)]
        let heads = DispatchPlanner.queueHeads(remaining)
        let jobs = [F.job(startedAt: F.firstStart, queueHeads: ["1@abc123", "2@abc123"])]
        let changedAt = DispatchPlanner.queueChangedAt(remaining, merged: [])
        #expect(changedAt == F.old)
        #expect(F.candidates(changedAt: changedAt, jobs: jobs, queueHeads: heads).count == 1)
    }

    @Test func queueHeadsAreSortedRegardlessOfInputOrder() {
        let prs = [F.pr(number: 2, headSha: "two"), F.pr(number: 10, headSha: "ten"), F.pr(headSha: "one")]
        #expect(DispatchPlanner.queueHeads(prs) == ["10@ten", "1@one", "2@two"])
        #expect(DispatchPlanner.queueHeads(Array(prs.reversed())) == ["10@ten", "1@one", "2@two"])
        #expect(DispatchPlanner.queueHeads([]).isEmpty)
    }

    @Test func futureDatedHeadNeverRearmsSuccessWithIdenticalHeads() {
        let future = F.now.addingTimeInterval(86400)
        let prs = [F.pr(headCommittedAt: future)]
        let heads = DispatchPlanner.queueHeads(prs)
        let changedAt = DispatchPlanner.queueChangedAt(prs, merged: [])
        let pushedAt = DispatchPlanner.queuePushedAt(prs)
        #expect(changedAt == F.old)
        #expect(pushedAt == future)
        let first = F.job(startedAt: F.firstStart, queueHeads: heads)
        let next = F.job(startedAt: F.laterStart, queueHeads: heads)
        for jobs in [[first], [first, next]] {
            #expect(F.candidates(changedAt: changedAt, pushedAt: pushedAt, jobs: jobs, queueHeads: heads).isEmpty)
        }
    }

    @Test func queuePushedAtUsesMaximumHeadCommitDate() {
        let prs = [F.pr(headCommittedAt: F.change), F.pr(number: 2, headCommittedAt: nil),
                   F.pr(number: 3, headCommittedAt: F.old)]
        #expect(DispatchPlanner.queuePushedAt(prs) == F.change)
        #expect(DispatchPlanner.queuePushedAt(Array(prs.reversed())) == F.change)
        #expect(DispatchPlanner.queuePushedAt([F.pr(headCommittedAt: nil)]) == nil)
        #expect(DispatchPlanner.queuePushedAt([]) == nil)
    }

    @Test func decodedCreationAndFilteredCommentsFeedQueueChangeGate() throws {
        func decode(created: Bool) throws -> PullRequest {
            func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
            var node: [String: Any] = [
                "number": 1, "title": "Synthetic widget", "url": "https://example.com/pr/1",
                "isDraft": false, "headRefOid": "abc123", "headRefName": "feature", "baseRefName": "main",
                "body": "", "updatedAt": stamp(F.now), "authorAssociation": "OWNER",
                "author": ["login": "octo"], "labels": ["nodes": []], "assignees": ["nodes": []],
                "comments": ["nodes": [
                    ["author": ["login": "octo"], "body": "Please check.", "createdAt": stamp(F.old)],
                    ["author": ["login": "octo"], "body": "Internal " + BtonMarker.prefix,
                     "createdAt": stamp(F.now)]
                ]]
            ]
            if created { node["createdAt"] = stamp(F.change) }
            let data = try JSONSerialization.data(withJSONObject: ["data": [
                "viewer": ["login": "octo"], "repository": ["defaultBranchRef": ["name": "main"],
                "pullRequests": ["nodes": [node]]]]])
            return try #require(GitHubClient.decodeOpenPullRequests(data, repo: F.repo).pullRequests.first)
        }
        let present = try decode(created: true), absent = try decode(created: false)
        #expect(present.createdAt == F.change)
        #expect(absent.createdAt == nil)
        for pr in [present, absent] {
            #expect(pr.comments.count == 1)
            #expect(pr.comments.first?.body == "Please check.")
            #expect(pr.comments.first?.createdAt == F.old)
        }
        let recent = DispatchPlanner.queueChangedAt([present], merged: [])
        let fallback = DispatchPlanner.queueChangedAt([absent], merged: [])
        #expect(recent == F.change)
        #expect(fallback == F.old)
        let jobs = [F.job(startedAt: F.firstStart)]
        #expect(F.candidates(changedAt: recent, jobs: jobs).count == 1)
        #expect(F.candidates(changedAt: fallback, jobs: jobs).isEmpty)
    }
}
