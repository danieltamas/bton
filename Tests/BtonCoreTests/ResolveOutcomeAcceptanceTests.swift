@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct ResolveOutcomeAcceptanceTests {
    private enum HeadLookupError: Error { case unavailable }

    @Test func changedHeadConfirmsResolvePush() async {
        let outcome = await DispatchPlanner.resolveOutcome(startedAt: "original-head") { "pushed-head" }
        #expect(outcome.status == .succeeded)
        #expect(outcome.detail == nil)
    }

    @Test func unchangedHeadFailsResolveWithPushedNothingDetail() async throws {
        let outcome = await DispatchPlanner.resolveOutcome(startedAt: "original-head") { "original-head" }
        #expect(outcome.status == .failed)
        let detail = try #require(outcome.detail)
        #expect(detail.hasPrefix("pushed nothing"))
    }

    @Test func headLookupErrorFailsResolveClosed() async throws {
        let outcome = await DispatchPlanner.resolveOutcome(startedAt: "original-head") {
            throw HeadLookupError.unavailable
        }
        #expect(outcome.status == .failed)
        let detail = try #require(outcome.detail)
        #expect(detail.hasPrefix("could not confirm the push"))
    }

    @Test(arguments: [false, true])
    func failedResolveCanRetryAndIsPlainWatchdogFailure(lookupThrows: Bool) async throws {
        let outcome = await DispatchPlanner.resolveOutcome(startedAt: "original-head") {
            if lookupThrows { throw HeadLookupError.unavailable }
            return "original-head"
        }
        let detail = try #require(outcome.detail)
        #expect(outcome.status == .failed)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = JobKey(repo: "synthetic/project", item: "pr-7", move: "resolve", head: "original-head")
        let job = Job(id: UUID(), key: key, agent: "synthetic", startedAt: now,
                      endedAt: now.addingTimeInterval(1), status: outcome.status, detail: detail, retry: nil)
        #expect(job.retry == nil)
        #expect(job.canRetry(among: [job]))
        #expect(Watchdog.flags(for: job, among: [job]) == [.failed])
    }

    @Test func decodeHeadReadsHeadRefOid() throws {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let data = Data("{\"headRefOid\":\"\(sha)\"}".utf8)
        #expect(try GitHubClient.decodeHead(data) == sha)
    }

    @Test(arguments: ["{}", "{\"headRefName\":\"feature\"}", "{\"headRefOid\":null}"])
    func decodeHeadRejectsMissingHeadRefOid(json: String) {
        #expect(throws: (any Error).self) {
            try GitHubClient.decodeHead(Data(json.utf8))
        }
    }
}
