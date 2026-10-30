import Foundation
import Testing
@testable import BtonCore

@Suite struct IntakeRetryRoundAcceptanceTests {
    typealias F = IntakeAcceptanceFixture

    private func comment(_ time: Double, author: String? = "outsider") -> IssueComment {
        IssueComment(id: String(time), author: author, authorAssociation: "NONE", body: "Decision",
                     createdAt: Date(timeIntervalSince1970: time), url: nil)
    }

    private func issue(_ comments: [IssueComment], assignees: [String] = []) -> OpenIssue {
        let seed = F.issue(assignees: assignees)
        return OpenIssue(repo: seed.repo, number: seed.number, title: seed.title, url: seed.url,
                         createdAt: seed.createdAt, author: seed.author, authorAssociation: seed.authorAssociation,
                         body: seed.body, comments: comments, labels: seed.labels, assignees: seed.assignees)
    }

    private func job(round: String = "1000", time: Double = 1100, retry: Bool = false,
                     number: Int = 7, repo: String = F.repo, move: String = "implement") -> Job {
        Job(id: UUID(), key: JobKey(repo: repo, item: "issue-\(number)", move: move, head: "", round: round),
            agent: "claude", startedAt: Date(timeIntervalSince1970: time), status: .failed, retry: retry)
    }

    @Test func latestJobUsesNewestStartAcrossRoundsAndRepoCasing() {
        let newest = job(round: "1000", time: 1200, repo: F.repo.uppercased())
        let jobs = [newest, job(round: "2000", time: 1100), job(time: 1300, number: 8),
                    job(time: 1400, repo: "other/repo"), job(time: 1500, move: "review")]
        #expect(IssueIntake.latestJob(for: 7, repo: F.repo, jobs: jobs)?.id == newest.id)
    }

    @Test func latestJobIsNilWithoutMatchingIntakeJob() {
        let jobs = [job(number: 8), job(repo: "other/repo"), job(move: "review")]
        #expect(IssueIntake.latestJob(for: 7, repo: F.repo, jobs: jobs) == nil)
        #expect(IssueIntake.latestJob(for: 7, repo: F.repo, jobs: []) == nil)
    }

    @Test func retryResumesAssignedIssueUnderItsOlderRound() throws {
        let earlier = issue([comment(1000)], assignees: ["me"])
        let retried = job(round: IssueIntake.round(of: earlier), retry: true)
        let updated = issue(earlier.comments + [comment(2000)], assignees: ["me"])
        let candidate = try #require(try F.candidate([updated], jobs: [retried]))
        #expect(candidate.key == retried.key)
        #expect(try F.plan(candidate).resumes)
    }

    @Test func assignedIssueWithoutRetryCannotStartANewerRound() throws {
        let earlier = issue([comment(1000)], assignees: ["me"])
        let finished = job(round: IssueIntake.round(of: earlier), retry: false)
        let updated = issue(earlier.comments + [comment(2000)], assignees: ["me"])
        #expect(try F.candidate([updated], jobs: [finished]) == nil)
    }

    @Test func freshUnassignedIssueUsesItsCurrentRound() throws {
        let ready = issue([comment(1000), comment(2000)])
        let candidate = try #require(try F.candidate([ready], jobs: []))
        #expect(candidate.key.round == IssueIntake.round(of: ready))
    }
}
