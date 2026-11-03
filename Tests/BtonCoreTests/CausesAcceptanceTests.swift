@testable import BtonCore
import Foundation
import Testing

enum CausesFixture {
    static let now = WatchdogFixture.now
    static func job(_ detail: String? = "agent exited 1", item: String = "pr-7",
                    repo: String = "synthetic/project", age: TimeInterval = 60,
                    status: Job.Status = .failed) -> Job {
        WatchdogFixture.job(status: status, detail: detail, cost: 0,
            key: JobKey(repo: repo, item: item, move: "fix", head: "same-head"), age: age)
    }
}

@Suite(ProcessBound())
struct CausesAcceptanceTests {
    @Test(arguments: [
        ("check `swift build` exited 1", "check:swift build"),
        ("posting the check failure failed: check `swift test` exited 1", "check:swift test"),
        ("checks not green: z gate failure, a success, more checks than were read", "red:a,z gate"),
        ("timed out after a minute", "timeout"), ("command ran 3 minutes and was stopped", "timeout"),
        (DispatchPlanner.endedWithoutPushing, "no-push"),
        ("agent exited 17", "agent-exit:17"), ("agent exited unknown", "agent-exit"),
        ("agent exited 1 after: check x", "agent-exit:1"),
        ("lease lost while renewing", "lease-lost"),
        ("posting the review failed: offline", "post-failed"),
        ("proves nothing: `test` already passes", "proves-nothing"),
        ("proof still red: `test` exited 1", "proof-red"),
        ("proof: `test` not found", "proof-failed"), ("environment: bad key", "environment")
    ])
    func structuredFailurePrefixDeterminesCause(detail: String, key: String) {
        #expect(Cause.key(for: CausesFixture.job(detail)) == key)
    }

    @Test(arguments: [nil, "free text", "gh says check `swift build` failed"] as [String?])
    func unstructuredOrMissingDetailHasNoCause(detail: String?) {
        #expect(Cause.key(for: CausesFixture.job(detail)) == nil)
    }

    @Test(arguments: [Job.Status.running, .succeeded, .cancelled])
    func onlyFailedJobsHaveCauses(status: Job.Status) {
        #expect(Cause.key(for: CausesFixture.job(status: status)) == nil)
    }

    @Test func repeatsAreDistinctOtherItemsOfSameRepoAndCauseInsideFourteenDays() {
        let job = CausesFixture.job()
        let jobs = [job, CausesFixture.job(item: "pr-7"), CausesFixture.job(item: "pr-9"),
            CausesFixture.job(item: "pr-8", repo: "SYNTHETIC/PROJECT"), CausesFixture.job(item: "pr-8"),
            CausesFixture.job(item: "pr-old", age: 14 * 86400 + 1),
            CausesFixture.job(item: "pr-future", age: -1), CausesFixture.job(item: "pr-other", repo: "other/repo"),
            CausesFixture.job("agent exited 2", item: "pr-different"),
            CausesFixture.job(item: "pr-success", status: .succeeded)]
        #expect(Cause.window == 14 * 86400)
        #expect(Cause.repeats(of: job, among: jobs, now: CausesFixture.now) == ["pr-8", "pr-9"])
        #expect(Cause.repeats(of: CausesFixture.job("free text"), among: jobs, now: CausesFixture.now).isEmpty)
    }

    @Test func recurringFlagRequiresAnotherItemAndIsLastCodableFlag() throws {
        let job = CausesFixture.job()
        #expect(!Watchdog.flags(for: job, among: [CausesFixture.job()]).contains(.recurring))
        #expect(Watchdog.flags(for: job, among: [CausesFixture.job(item: "pr-8")]).contains(.recurring))
        #expect(JobFlag.allCases.last == .recurring)
        #expect(JobFlag.recurring.rawValue == "recurring")
        #expect(try JSONDecoder().decode(JobFlag.self, from: JSONEncoder().encode(JobFlag.recurring)) == .recurring)
    }

    @Test(arguments: [true, false])
    func supervisorPromptNamesCauseAndRecurringItemsOrNone(recurring: Bool) throws {
        var job = CausesFixture.job(recurring ? "agent exited 1" : "free text")
        job.flags = [.failed]
        let other = CausesFixture.job(item: "pr-8", age: 120)
        let pr = PullRequest(repo: job.key.repo, number: 7, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: "same-head", headRef: "feature", baseRef: "main", body: "", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: CausesFixture.now)
        let candidate = try #require(Supervision.candidate(settings: SupervisorSettings(enabled: true),
            agents: ["claude": AgentTemplate(argv: ["claude", "{prompt}"])], jobs: [job, other],
            repo: job.key.repo, pullRequests: [pr], defaultBranch: "main", me: "owner",
            now: CausesFixture.now, log: { _ in "log" }))
        let prompt = try #require(candidate.prompt)
        #expect(prompt.contains(recurring ? "cause: agent-exit:1\nrecurring on: pr-8" : "cause: none\nrecurring on: none"))
        #expect(Supervision.defaultPrompt.contains("A cause marked recurring failed the same way on other items of this repo: that is a setup problem, so prefer propose, and say which rule or check would catch it before the next run."))
    }

    @Test func recurringKnownFailureKeepsItsKnownAnswer() {
        var job = CausesFixture.job("checks not green: gate failure")
        let original = Supervision.knownAnswer(for: job)
        job.flags = [.failed, .recurring]
        #expect(original != nil)
        #expect(Supervision.knownAnswer(for: job) == original)
    }
}
