@testable import BtonCore
import Testing
import Foundation

@Suite(ProcessBound())
struct StaleReviewAcceptanceTests {
    private enum HeadLookupError: Error { case unavailable }
    private static let oldHead = "abcdef1" + String(repeating: "a", count: 33)
    private static let newHead = "1234567" + String(repeating: "b", count: 33)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func unchangedHeadAllowsPosting() async {
        let detail = await DispatchPlanner.staleReviewDetail(reviewedHead: Self.oldHead) { Self.oldHead }
        #expect(detail == nil)
    }

    @Test func movedHeadDropsReviewWithShortHeads() async throws {
        let detail = try #require(await DispatchPlanner.staleReviewDetail(reviewedHead: Self.oldHead) { Self.newHead })
        #expect(detail.hasPrefix("head moved from "))
        #expect(detail.contains("head moved from abcdef1 to 1234567"))
        #expect(!detail.contains(Self.oldHead))
        #expect(!detail.contains(Self.newHead))
        #expect(detail.hasSuffix("nothing posted"))
    }

    @Test func unconfirmedHeadDropsReview() async throws {
        let detail = try #require(await DispatchPlanner.staleReviewDetail(reviewedHead: Self.oldHead) {
            throw HeadLookupError.unavailable
        })
        #expect(detail.hasPrefix("could not confirm the head before posting"))
        #expect(detail.hasSuffix("nothing posted"))
        let job = Self.job(status: .failed, detail: detail)
        #expect(job.canRetry(among: [job]))
    }

    @Test func movedHeadFailureNeedsNoSupervisorAndOffersRetry() async throws {
        let detail = try #require(await DispatchPlanner.staleReviewDetail(reviewedHead: Self.oldHead) { Self.newHead })
        let job = Self.job(status: .failed, detail: detail)
        let verdict = try #require(Supervision.knownAnswer(for: job))
        #expect(verdict.action == .none)
        #expect(Watchdog.flags(for: job, among: [job]).contains(.failed))
        #expect(job.canRetry(among: [job]))
    }

    @Test func staleRunningReviewsKeepInputOrderAndMatchRepoIgnoringCase() {
        let first = Self.job(repo: "Synthetic/Project", number: 739)
        let second = Self.job()
        let current = Self.job(head: Self.newHead)
        let jobs = [first, current, second]
        let prs = [Self.pr(number: 738), Self.pr(number: 739)]
        #expect(Engine.staleReviews(jobs, pullRequests: prs).map(\.id) == [first.id, second.id])
    }

    @Test func missingPRAndWrongRepoOrNumberDoNotEstablishStaleness() {
        let job = Self.job()
        #expect(Engine.staleReviews([job], pullRequests: []).isEmpty)
        #expect(Engine.staleReviews([job], pullRequests: [Self.pr(repo: "other/project")]).isEmpty)
        #expect(Engine.staleReviews([job], pullRequests: [Self.pr(number: 739)]).isEmpty)
    }

    @Test func onlyPRReviewsAreDropped() {
        let fix = Self.job(review: false)
        let issue = Self.job(item: "issue-738")
        #expect(Engine.staleReviews([fix, issue], pullRequests: [Self.pr()]).isEmpty)
    }

    @Test(arguments: [Job.Status.succeeded, .failed, .cancelled])
    func finishedJobsAreNotDropped(status: Job.Status) {
        let review = Self.job(status: status)
        let fix = Self.job(status: status, review: false)
        #expect(Engine.staleReviews([review, fix], pullRequests: [Self.pr()]).isEmpty)
    }

    private static func job(repo: String = "synthetic/project", number: Int = 738,
                            item: String? = nil, head: String = oldHead,
                            status: Job.Status = .running, detail: String? = nil,
                            review: Bool = true) -> Job {
        let key = JobKey(repo: repo, item: item ?? "pr-\(number)", move: review ? "review" : "fix", head: head)
        var job = Job(id: UUID(), key: key, agent: "codex", startedAt: now,
                      endedAt: status == .running ? nil : now.addingTimeInterval(1),
                      status: status, detail: detail, retry: nil)
        if review {
            job.review = ReviewTarget(number: number, head: head, headings: ["## Review:"], clearLabels: nil)
        }
        return job
    }

    private static func pr(repo: String = "synthetic/project", number: Int = 738) -> PullRequest {
        PullRequest(repo: repo, number: number, title: "Synthetic PR", author: "owner",
                    authorAssociation: "MEMBER", url: URL(string: "https://example.invalid/pr/\(number)")!,
                    headSha: newHead, headRef: "feature", baseRef: "main", body: "Tier: feature", isDraft: false,
                    labels: [], assignees: [], comments: [], updatedAt: now)
    }
}
