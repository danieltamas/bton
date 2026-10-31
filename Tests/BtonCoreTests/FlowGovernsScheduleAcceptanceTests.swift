@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct FlowGovernsScheduleAcceptanceTests {
    @Test func scheduleOnRepoWithFlowNeverStarts() async throws {
        let f = try await StartMovesFixture.make(startMoves: true, schedule: true)
        defer { f.remove() }
        let snapshot = try await f.engine().tick()
        #expect(snapshot.problem == nil)
        #expect(snapshot.jobs.contains { $0.key == f.key("fix") })
        #expect(!snapshot.jobs.contains { $0.key.move == "schedule" })
        try await f.waitForJobs()
    }

    @Test func scheduleOnRepoWithFlowIgnoresRunNow() async throws {
        let f = try await StartMovesFixture.make(startMoves: false, schedule: true)
        defer { f.remove() }
        let engine = try f.engine()
        await engine.runNext(repo: f.repo, item: "schedule-1")
        let snapshot = await engine.tick()
        #expect(snapshot.problem == nil)
        #expect(!snapshot.jobs.contains { $0.key.move == "schedule" })
        #expect(!snapshot.jobs.contains { $0.key == f.key("fix") })
    }

    @Test func scheduleRunsRepoWithoutFlow() async throws {
        let f = try await StartMovesFixture.make(startMoves: true, schedule: true, flow: false)
        defer { f.remove() }
        let snapshot = try await f.engine().tick()
        #expect(snapshot.problem == nil)
        #expect(snapshot.jobs.map(\.key.move) == ["schedule"])
        let pr = try #require(snapshot.openPullRequests.first)
        #expect(pr.move == nil)
        try await f.waitForJobs()
    }
}
