import BtonCore
import Foundation
import Testing

// Shared only by the two U8 acceptance suites; no production test hooks.
enum WatchdogFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let key = JobKey(repo: "synthetic/project", item: "pr-7", move: "fix", head: "same-head")
    static func job(status: Job.Status = .failed, detail: String? = nil,
                    cost: Decimal? = nil, key: JobKey = key, age: TimeInterval = 60) -> Job {
        Job(id: UUID(), key: key, agent: "claude", startedAt: now.addingTimeInterval(-age - 60),
            endedAt: status == .running ? nil : now.addingTimeInterval(-age),
            status: status, detail: detail, cost: cost)
    }
}

@Suite(ProcessBound())
struct WatchdogAcceptanceTests {
    @Test func jobFlagsHaveStableCodableNames() throws {
        let names = ["timedOut", "leaseLost", "noVerdict", "postFailed", "agentFailed", "failed", "repeated", "costly", "loggedOut"]
        #expect(JobFlag.allCases.map(\.rawValue) == names)
        let data = try JSONEncoder().encode(JobFlag.allCases)
        #expect(try JSONDecoder().decode([JobFlag].self, from: data) == JobFlag.allCases)
    }

    @Test(arguments: [
        ("timed out", JobFlag.timedOut), ("lease lost while renewing", .leaseLost),
        ("final message names no supervisor verdict", .noVerdict),
        ("posting the review failed: offline", .postFailed),
        ("decision posted; remove label failed", .postFailed),
        ("agent exited 1", .agentFailed), ("other failure", .failed),
        ("timed out later", .failed)
    ])
    func failureDetailFlagTable(detail: String, flag: JobFlag) {
        #expect(Watchdog.flags(for: WatchdogFixture.job(detail: detail), among: []) == [flag])
    }

    @Test func nilDetailFailsAndInactiveStatusesHaveNoFlags() {
        #expect(Watchdog.flags(for: WatchdogFixture.job(), among: []) == [.failed])
        for status in [Job.Status.running, .cancelled, .succeeded] {
            #expect(Watchdog.flags(for: WatchdogFixture.job(status: status, detail: "timed out"), among: []) == [])
        }
    }

    @Test func repeatedCountsEachIDOnceAndOnlyFailedSameKey() {
        let job = WatchdogFixture.job()
        #expect(Watchdog.flags(for: job, among: [job, job]) == [.failed])
        let previous = WatchdogFixture.job()
        #expect(Watchdog.flags(for: job, among: [previous]) == [.failed, .repeated])
        #expect(Watchdog.flags(for: job, among: [job, previous, previous]) == [.failed, .repeated])
        let other = JobKey(repo: job.key.repo, item: "pr-8", move: job.key.move, head: job.key.head)
        #expect(Watchdog.flags(for: job, among: [WatchdogFixture.job(key: other),
            WatchdogFixture.job(status: .succeeded)]) == [.failed])
    }

    @Test func costlyNeedsFiveSamplesDollarFloorAndStrictMedianMultiplier() {
        let samples = (0..<5).map { WatchdogFixture.job(status: .succeeded, cost: Decimal(string: "0.25"), age: Double($0 + 1)) }
        let costly = WatchdogFixture.job(status: .succeeded, cost: 1)
        #expect(Watchdog.flags(for: costly, among: Array(samples.prefix(4))) == [])
        #expect(Watchdog.flags(for: costly, among: samples + [costly]) == [.costly])
        #expect(Watchdog.flags(for: WatchdogFixture.job(cost: 1), among: samples) == [.failed, .costly])
        #expect(Watchdog.flags(for: WatchdogFixture.job(status: .cancelled, cost: 9), among: samples) == [])
        #expect(Watchdog.flags(for: WatchdogFixture.job(status: .succeeded, cost: Decimal(string: "0.99")), among: samples) == [])
        let equal = (0..<5).map { _ in WatchdogFixture.job(status: .succeeded, cost: 1) }
        #expect(Watchdog.flags(for: WatchdogFixture.job(status: .succeeded, cost: 3), among: equal) == [])
    }

    @Test func costlyUsesMedianRatherThanMean() {
        let costs = ["0.1", "0.2", "0.3", "0.4", "10"]
        let samples = costs.map { WatchdogFixture.job(status: .succeeded, cost: Decimal(string: $0)) }
        #expect(Watchdog.flags(for: WatchdogFixture.job(status: .succeeded, cost: 1), among: samples) == [.costly])
    }

    @Test func costlyUsesLatestTwentyKnownSuccessesOfRepoAndMove() {
        let matching = JobKey(repo: "SYNTHETIC/PROJECT", item: "pr-9", move: "fix", head: "other")
        let recent = (0..<20).map { WatchdogFixture.job(status: .succeeded, cost: 1, key: matching, age: Double($0 + 1)) }
        let old = (0..<30).map { WatchdogFixture.job(status: .succeeded, cost: 100, age: Double(100 + $0)) }
        let job = WatchdogFixture.job(status: .succeeded, cost: 4)
        #expect(Watchdog.flags(for: job, among: old + recent) == [.costly])
        let wrongMove = JobKey(repo: matching.repo, item: matching.item, move: "review", head: matching.head)
        let wrongRepo = JobKey(repo: "other/project", item: matching.item, move: "fix", head: matching.head)
        let excluded = (0..<5).flatMap { _ in [WatchdogFixture.job(status: .succeeded, cost: 0, key: wrongMove),
            WatchdogFixture.job(status: .succeeded, cost: 0, key: wrongRepo),
            WatchdogFixture.job(cost: 0), WatchdogFixture.job(status: .succeeded)] }
        #expect(Watchdog.flags(for: job, among: excluded) == [])
        let failed = WatchdogFixture.job(detail: "timed out", cost: 4)
        #expect(Watchdog.flags(for: failed, among: recent + [WatchdogFixture.job()]) == [.timedOut, .repeated, .costly])
    }

    @Test func legacyJobOmitsAndDecodesNewOptionalFields() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111",
         "key":{"repo":"synthetic/project","item":"pr-7","move":"fix","head":"same-head"},
         "startedAt":100,"status":"failed","usage":{}}
        """
        let job = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        #expect(job.flags == nil)
        #expect(job.supervises == nil)
        #expect(job.steered == nil)
        #expect(job.verdict == nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        for field in ["flags", "supervises", "steered", "verdict"] { #expect(object[field] == nil) }
        var populated = job
        populated.flags = [.failed]
        populated.supervises = UUID()
        populated.steered = true
        populated.verdict = Supervision.verdict(fromFinalMessage: "## Supervisor: none")
        #expect(try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(populated)) == populated)
    }

    @Test func finishPersistsFlagsThroughRealDispatcher() async throws {
        let run = try await SupervisionRunFixture.make()
        defer { try? FileManager.default.removeItem(at: run.leases.root) }
        let ended = try await run.run(move: "fix", final: "unused", exit: 7)
        #expect(ended.status == .failed)
        #expect(ended.flags == [.agentFailed])
        let reloaded = try JobStore(home: run.home).all().first { $0.id == ended.id }
        #expect(reloaded?.flags == [.agentFailed])
    }
}
