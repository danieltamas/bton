@testable import BtonCore
import Foundation
import Testing

private enum ScheduleHoldFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let agents = ["synthetic": AgentTemplate(argv: ["/usr/bin/true"])]

    static func candidate(_ repo: String = "owner/a", _ number: Int = 1,
                          schedule: Bool = false) -> DispatchCandidate {
        let pr = PullRequest(repo: repo, number: number, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/\(number)")!,
            headSha: "synthetic-head", headRef: "feat/x", baseRef: "main", body: "",
            isDraft: false, labels: [], assignees: [], comments: [], updatedAt: now)
        let move = schedule ? "schedule" : "review"
        return DispatchCandidate(target: schedule ? .branch("main") : .pullRequest(pr),
            move: Move(name: move, owner: "owner", ownerFromRotation: false, tier: "", hasDispatch: true),
            key: JobKey(repo: repo, item: schedule ? "schedule-\(number)" : "pr-\(number)",
                        move: move, head: "synthetic-head"),
            agent: "synthetic", prompt: "Synthetic", command: nil, postComment: false, timeout: .seconds(60))
    }

    static func job(_ repo: String = "owner/a", _ number: Int = 99,
                    schedule: Bool = true, status: Job.Status = .running) -> Job {
        Job(id: UUID(), key: candidate(repo, number, schedule: schedule).key,
            agent: "synthetic", startedAt: now.addingTimeInterval(-60), status: status)
    }

    static func select(_ candidates: [DispatchCandidate], jobs: [Job] = [], max: Int = 10,
                       first: [String] = []) -> [JobKey] {
        DispatchPlanner.select(candidates, jobs: jobs, maxAgents: max, agents: agents,
                               first: first).map(\.key)
    }
}

struct ScheduleHoldAcceptanceTests {
    @Test func runningScheduleAllowsUnheldPRInSameRepo() {
        let pr = ScheduleHoldFixture.candidate("OWNER/A", 7)
        #expect(ScheduleHoldFixture.select([pr], jobs: [ScheduleHoldFixture.job()]) == [pr.key])
    }

    @Test func scheduleWaitsForRunningPRInSameRepo() {
        let schedule = ScheduleHoldFixture.candidate("OWNER/A", 1, schedule: true)
        #expect(ScheduleHoldFixture.select([schedule],
            jobs: [ScheduleHoldFixture.job(schedule: false)]).isEmpty)
    }

    @Test func scheduleWaitsForRunningScheduleInSameRepo() {
        let schedule = ScheduleHoldFixture.candidate("OWNER/A", 1, schedule: true)
        #expect(ScheduleHoldFixture.select([schedule], jobs: [ScheduleHoldFixture.job()]).isEmpty)
    }

    @Test func prPrecedesScheduleAndExcludesItFromSamePick() {
        let schedule = ScheduleHoldFixture.candidate("OWNER/A", 1, schedule: true)
        let pr = ScheduleHoldFixture.candidate("owner/a", 7)
        #expect(ScheduleHoldFixture.select([schedule, pr]) == [pr.key])
    }

    @Test func atMostOneSchedulePerRepoStarts() {
        let a = ScheduleHoldFixture.candidate("owner/a", 1, schedule: true)
        let b = ScheduleHoldFixture.candidate("OWNER/A", 2, schedule: true)
        let selected = ScheduleHoldFixture.select([a, b])
        #expect(selected.count == 1)
        #expect(selected.allSatisfy { [a.key, b.key].contains($0) })
    }

    @Test func runningScheduleCountsAgainstGlobalCapacity() {
        let a = ScheduleHoldFixture.candidate("owner/a", 7)
        let b = ScheduleHoldFixture.candidate("owner/b", 8)
        let jobs = [ScheduleHoldFixture.job()]
        #expect(ScheduleHoldFixture.select([a, b], jobs: jobs, max: 1).isEmpty)
        #expect(ScheduleHoldFixture.select([a, b], jobs: jobs, max: 2) == [a.key])
    }

    @Test func runningScheduleDoesNotBlockScheduleInAnotherRepo() {
        let schedule = ScheduleHoldFixture.candidate("owner/b", 1, schedule: true)
        #expect(ScheduleHoldFixture.select([schedule], jobs: [ScheduleHoldFixture.job()]) == [schedule.key])
    }

}
