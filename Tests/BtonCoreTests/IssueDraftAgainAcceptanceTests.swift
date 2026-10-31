@testable import BtonCore
import Foundation
import Testing

struct IssueDraftAgainAcceptanceTests {
    @Test func leavesToDoRecognizesOnlyTheTrimmedLastLineIgnoringCase() {
        #expect(IssueDrafts.leavesToDo("Reply.\nTo do: choose a stage"))
        #expect(IssueDrafts.leavesToDo(" \nReply.\n  to do: choose a stage \t\n\n"))
        #expect(IssueDrafts.leavesToDo("Reply.\n\tTO DO: choose a stage\t\n"))
        #expect(IssueDrafts.leavesToDo("Reply.\n  tO dO:"))
        #expect(!IssueDrafts.leavesToDo("Reply without a pending task."))
        #expect(!IssueDrafts.leavesToDo("To do: choose a stage\nMore text follows."))
        #expect(!IssueDrafts.leavesToDo("Reply mentions To do: inline."))
        #expect(!IssueDrafts.leavesToDo(""))
        #expect(!IssueDrafts.leavesToDo(" \t\n\n"))
    }

    @Test func canRunAgainRequiresLatestSucceededIssueDraftWithoutRetry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = JobKey(repo: "synthetic/project", item: "issue-7",
                         move: IssueDrafts.move, head: "asking-comment")
        let job = Job(id: UUID(), key: key, agent: "synthetic", startedAt: now,
                      endedAt: now.addingTimeInterval(1), status: .succeeded,
                      detail: "Synthetic outcome")
        #expect(job.canRunAgain(among: [job]))

        var retry = job
        retry.retry = true
        #expect(!retry.canRunAgain(among: [retry]))

        var failed = job
        failed.status = .failed
        #expect(!failed.canRunAgain(among: [failed]))

        let decisionKey = JobKey(repo: key.repo, item: key.item,
                                 move: IssueDecisions.move, head: key.head)
        let decision = Job(id: UUID(), key: decisionKey, agent: "synthetic", startedAt: now,
                           endedAt: now.addingTimeInterval(1), status: .succeeded,
                           detail: "Synthetic outcome")
        #expect(!decision.canRunAgain(among: [decision]))

        let newer = Job(id: UUID(), key: key, agent: "synthetic",
                        startedAt: now.addingTimeInterval(10), status: .running)
        #expect(!job.canRunAgain(among: [job, newer]))
    }
}
