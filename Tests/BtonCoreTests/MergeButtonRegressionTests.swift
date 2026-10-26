@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct MergeButtonRegressionTests {
    @Test(arguments: ["merge", "resolve"])
    func teammateFlowMoveRunsOnceInSyncOnlyRepo(move: String) async throws {
        let f = try await StartMovesFixture.make(startMoves: false, conflicting: move == "resolve")
        defer { f.remove() }
        try configure(f, move: move)
        let engine = try f.engine()
        let before = await engine.tick()
        #expect(before.problem == nil)
        #expect(before.jobs.isEmpty)
        let pr = try #require(before.openPullRequests.first)
        #expect(pr.author == "teammate")
        #expect(pr.move?.name == move)
        #expect(pr.move?.owner == "owner")
        #expect(pr.move?.hasDispatch == true)

        try await engine.runNow(f.key(move))
        let first = await engine.tick()
        #expect(first.problem == nil)
        #expect(first.jobs.map(\.key) == [f.key(move)])
        #expect(first.next.isEmpty)
        try await f.waitForJobs()
        let second = await engine.tick()
        #expect(second.problem == nil)
        // Snapshots retain completed jobs: an unchanged ID proves no second start.
        #expect(second.jobs.map(\.id) == first.jobs.map(\.id))
        #expect(second.jobs.map(\.key) == [f.key(move)])
        try await f.waitForJobs()
    }

    @Test func ownPRStillAcceptsMergeOverrideOfDifferentFlowMove() async throws {
        let f = try await StartMovesFixture.make(startMoves: false)
        defer { f.remove() }
        let engine = try f.engine()
        let before = await engine.tick()
        #expect(before.problem == nil)
        #expect(before.openPullRequests.first?.author == "owner")
        #expect(before.openPullRequests.first?.move?.name == "fix")
        #expect(before.jobs.isEmpty)
        try await engine.runNow(f.key("merge"))
        let after = await engine.tick()
        #expect(after.problem == nil)
        #expect(after.jobs.map(\.key) == [f.key("merge")])
        #expect(after.next.isEmpty)
        try await f.waitForJobs()
    }

    @Test(arguments: ["merge", "resolve"])
    func oldHeadRequestCannotStartCurrentFlowMove(move: String) async throws {
        let f = try await StartMovesFixture.make(startMoves: false, conflicting: move == "resolve")
        defer { f.remove() }
        try configure(f, move: move)
        let engine = try f.engine()
        #expect(await engine.tick().jobs.isEmpty)
        try await engine.runNow(f.key(move))
        try f.updatePRs(head: "new-head", conflicting: move == "resolve")
        for _ in 0..<2 {
            let snapshot = await engine.tick()
            #expect(snapshot.problem == nil)
            #expect(snapshot.openPullRequests.first?.headSha == "new-head")
            #expect(snapshot.jobs.isEmpty)
            #expect(snapshot.next.isEmpty)
        }
    }

    @Test func queuedMergeMustNotFollowHeadAfterBusyTick() async throws {
        let f = try await StartMovesFixture.make(startMoves: false)
        defer { f.remove() }
        try configure(f, move: "merge")
        let other = try f.leases.store("other")
        let held = try RetryLeaseFixture.claimed(await other.claim(f.leases.item, in: f.repo, key: "schedule-agent"))
        let engine = try f.engine()
        try await engine.runNow(f.key("merge"))
        let busy = await engine.tick()
        #expect(busy.problem == nil)
        #expect(busy.jobs.isEmpty)
        #expect(busy.next == ["synthetic/project#pr-7"])
        try f.updatePRs(head: "new-head")
        try await other.release(held)
        let after = await engine.tick()
        #expect(after.problem == nil)
        #expect(after.jobs.isEmpty)
        #expect(after.next.isEmpty)
        try await f.waitForJobs()
    }

    @Test(arguments: ["someone-else", "missing-dispatch", "wrong-base", "untrusted"])
    func matchingMergeDoesNotBypassDispatchEligibility(blocker: String) async throws {
        let f = try await StartMovesFixture.make(startMoves: false)
        defer { f.remove() }
        try configure(f, move: "merge", blocker: blocker)
        let engine = try f.engine()
        try await engine.runNow(f.key("merge"))
        let snapshot = await engine.tick()
        #expect(snapshot.problem == nil)
        #expect(snapshot.jobs.isEmpty)
        #expect(snapshot.next.isEmpty)
    }

    private func configure(_ f: StartMovesFixture, move: String, blocker: String? = nil) throws {
        let gh = f.root.appendingPathComponent("gh")
        var script = try String(contentsOf: gh, encoding: .utf8)
        let flowLine = try #require(script.components(separatedBy: "\n").first { $0.hasPrefix("{\"version\":") })
        var flow = try #require(JSONSerialization.jsonObject(with: Data(flowLine.utf8)) as? [String: Any])
        flow["moves"] = [["move": move, "when": [move == "resolve" ? "conflicting" : "no_review_or_response_newer"],
                          "who": blocker == "someone-else" ? "someone-else" : "owner"]]
        if blocker == "missing-dispatch" {
            var dispatch = try #require(flow["dispatch"] as? [String: Any])
            dispatch.removeValue(forKey: move)
            flow["dispatch"] = dispatch
        }
        script = script.replacingOccurrences(of: flowLine,
            with: String(decoding: try JSONSerialization.data(withJSONObject: flow), as: UTF8.self))
        script = script.replacingOccurrences(of: #""author":{"login":"owner"}"#,
                                            with: #""author":{"login":"teammate"}"#)
        if blocker == "wrong-base" {
            script = script.replacingOccurrences(of: #""baseRefName":"main""#, with: #""baseRefName":"other""#)
        }
        if blocker == "untrusted" {
            script = script.replacingOccurrences(of: #""authorAssociation":"OWNER""#,
                                                with: #""authorAssociation":"NONE""#)
        }
        try script.write(to: gh, atomically: true, encoding: .utf8)
    }
}
