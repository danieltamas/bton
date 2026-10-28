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
                   headCommittedAt: Date? = old, comments: [PullRequestComment] = []) -> PullRequest {
        var pr = PullRequest(repo: repo, number: number, title: "Synthetic widget", author: "octo",
                             authorAssociation: "OWNER", url: URL(string: "https://example.com/pr/\(number)")!,
                             headSha: "abc123", headRef: "feature", baseRef: "main", body: "",
                             isDraft: false, labels: [], assignees: [], comments: comments, updatedAt: updatedAt)
        pr.createdAt = createdAt
        pr.headCommittedAt = headCommittedAt
        return pr
    }

    static func comment(at date: Date) -> PullRequestComment {
        PullRequestComment(author: "octo", body: "Please check the widget.", createdAt: date)
    }

    static func job(startedAt: Date) -> Job {
        Job(id: UUID(), key: JobKey(repo: repo, item: "schedule-7", move: "schedule", head: "old-minute"),
            agent: "codex", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60), status: .succeeded)
    }

    static func candidates(changedAt: Date?, jobs: [Job]) -> [DispatchCandidate] {
        var entry = ScheduleEntry(name: "Daily check", everyMinutes: 10, enabled: true,
                                  repo: repo, agent: "codex", prompt: "Inspect the synthetic widget.", number: 7)
        entry.onlyOnChange = true
        return DispatchPlanner.scheduled([entry], jobs: jobs, repo: repo, defaultBranch: "main",
                                         me: "octo", now: now, changedAt: changedAt)
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
        let changedAt = DispatchPlanner.queueChangedAt([F.pr(headCommittedAt: F.change)], merged: [])
        #expect(changedAt == F.change)
        let first = F.job(startedAt: F.firstStart)
        #expect(F.candidates(changedAt: changedAt, jobs: [first]).count == 1)
        #expect(F.candidates(changedAt: changedAt, jobs: [first, F.job(startedAt: F.laterStart)]).isEmpty)
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
}
