@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct DroppedAskAcceptanceTests {
    private let dropped = "synthetic/project#7: merge not started: the flow does not ask for a merge on it now"

    // P1-P4: the same rejection must consume the press at both public entrances.
    @Test(arguments: ["merge", "retry"], [false, true])
    func droppedMergeAskCannotPressTheFlowsFix(entrance: String, watched: Bool) async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let key = try await prepareObservedFix(f, agentFix: watched)
        let store = try JobStore(home: f.home)
        var priorIDs = Set<UUID>()
        var failedID: UUID?
        if entrance == "retry" {
            var failed = Job(id: UUID(), key: key, agent: nil,
                startedAt: .now.addingTimeInterval(-60), endedAt: .now.addingTimeInterval(-30),
                status: .failed, detail: "command exited 1", cost: 0)
            failed.flags = [.failed]
            try store.save(failed)
            failedID = failed.id
            priorIDs.insert(failed.id)
        }
        let other = try f.leases.store("other")
        let held = try RetryLeaseFixture.claimed(await other.claim(f.leases.item, in: f.repo, key: "busy"))
        let log = MoveLog()
        let engine = try f.engine(log: { log.append($0) })
        if let failedID { #expect(try await engine.retry(failedID)) }
        else { try await engine.runNow(key) }
        let queued = await engine.tick()
        #expect(queued.problem == nil)
        #expect(Set(queued.jobs.map(\.id)) == priorIDs)
        #expect(queued.next == [Engine.pick(repo: f.repo, item: "pr-7")])
        #expect(queued.openPullRequests.first?.move?.name == "merge")
        try f.reviews(["approve", "changes"])
        if watched { try mark(f) }
        try await other.release(held)

        let rejected = await engine.tick()
        #expect(rejected.problem == nil)
        #expect(rejected.openPullRequests.first?.headSha == key.head)
        #expect(rejected.openPullRequests.first?.move?.name == "fix")
        #expect(rejected.openPullRequests.first?.heldBySession == watched)
        #expect(log.all.contains(dropped))
        #expect(rejected.next.isEmpty)
        let started = rejected.jobs.filter { !priorIDs.contains($0.id) }
        #expect(!started.contains { $0.key.move == "merge" })
        if watched {
            #expect(started.isEmpty)
            let later = await engine.tick()
            #expect(later.problem == nil)
            #expect(Set(later.jobs.map(\.id)) == priorIDs)
            #expect(later.openPullRequests.first?.heldBySession == true)
            // Once the session leaves, the flow still must not inherit the old press.
            try SessionWatch(home: f.home).clear(repo: f.repo, number: 7, holder: "author-session")
            let resumed = await engine.tick()
            #expect(resumed.problem == nil)
            let jobs = resumed.jobs.filter { !priorIDs.contains($0.id) }
            #expect(jobs.count == 1)
            let fix = try #require(jobs.first)
            #expect(fix.key.move == "fix")
            #expect(fix.key.head == key.head)
            #expect(fix.pressed != true)
        } else {
            #expect(started.count == 1)
            let fix = try #require(started.first)
            #expect(fix.key.move == "fix")
            #expect(fix.key.head == key.head)
            #expect(fix.pressed != true)
        }
        try await f.waitForJobs()
        try expectMarkers(f, checksAndCommand: "absent", agentFix: watched)
    }

    @Test func pressedRunNextStartsWatchedAgentFixWithoutAnAsk() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let key = try await prepareObservedFix(f, agentFix: true)
        try f.reviews(["approve", "changes"])
        try mark(f)
        let log = MoveLog()
        let engine = try f.engine(log: { log.append($0) })
        await engine.runNext(repo: f.repo, item: "pr-7", pressed: true)

        let next = await engine.tick()
        #expect(next.problem == nil)
        #expect(next.jobs.count == 1)
        let fix = try #require(next.jobs.first)
        #expect(fix.key.move == "fix")
        #expect(fix.key.head == key.head)
        #expect(fix.agent == "synthetic")
        #expect(fix.pressed == true)
        #expect(next.openPullRequests.first?.author == "owner")
        #expect(next.openPullRequests.first?.heldBySession == false)
        #expect(SessionWatch(home: f.home).isWatched(repo: f.repo, number: 7))
        #expect(next.next.isEmpty)
        #expect(!log.all.contains { $0.contains("not started") })
        try await f.waitForJobs()
        try expectMarkers(f, checksAndCommand: "1", agentFix: true)
    }

    // P5: the older head-moved drop must also happen before the session hold.
    @Test(arguments: [false, true])
    func droppedResolveAskCannotPressTheNewHead(watched: Bool) async throws {
        let f = try await StartMovesFixture.make(startMoves: true, conflicting: true)
        defer { f.remove() }
        try f.prepareMerge()
        var config = try BtonConfig.loadOrCreate(home: f.home)
        config.repos[0].resolveConflicts = true
        try config.save(to: f.home.configURL)
        let log = MoveLog()
        let engine = try f.engine(log: { log.append($0) })
        try await engine.runNow(f.key("resolve"))
        try f.updatePRs(head: "new-head", conflicting: true)
        if watched { try mark(f) }
        let moved = await engine.tick()
        #expect(moved.problem == nil)
        #expect(moved.openPullRequests.first?.headSha == "new-head")
        #expect(moved.openPullRequests.first?.conflicting == true)
        #expect(moved.openPullRequests.first?.heldBySession == watched)
        #expect(log.all.contains("synthetic/project#7: resolve not started: the head moved"))
        if watched {
            #expect(moved.jobs.isEmpty)
            let later = await engine.tick()
            #expect(later.problem == nil)
            #expect(later.jobs.isEmpty)
            #expect(later.openPullRequests.first?.heldBySession == true)
        } else {
            #expect(moved.jobs.count == 1)
            let resolve = try #require(moved.jobs.first)
            #expect(resolve.key.move == "resolve")
            #expect(resolve.key.head == "new-head")
            #expect(resolve.pressed != true)
        }
        try await f.waitForJobs()
    }

    // P6: Run next is a new request, not the old Merge ask with another label.
    @Test func newerRunNextKeepsItsOwnPressAndForgetsTheMergeAsk() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let key = try await prepareObservedFix(f)
        let other = try f.leases.store("other")
        let held = try RetryLeaseFixture.claimed(await other.claim(f.leases.item, in: f.repo, key: "busy"))
        let log = MoveLog()
        let engine = try f.engine(log: { log.append($0) })
        try await engine.runNow(key)
        let queued = await engine.tick()
        #expect(queued.problem == nil)
        #expect(queued.jobs.isEmpty)
        #expect(queued.next == [Engine.pick(repo: f.repo, item: "pr-7")])
        #expect(queued.openPullRequests.first?.move?.name == "merge")
        await engine.runNext(repo: f.repo, item: "pr-7", pressed: true)
        try f.reviews(["approve", "changes"])
        try mark(f)
        try await other.release(held)
        let next = await engine.tick()
        #expect(next.problem == nil)
        #expect(next.jobs.count == 1)
        let fix = try #require(next.jobs.first)
        #expect(fix.key.move == "fix")
        #expect(fix.key.head == key.head)
        #expect(fix.pressed == true)
        #expect(next.openPullRequests.first?.heldBySession == false)
        #expect(SessionWatch(home: f.home).isWatched(repo: f.repo, number: 7))
        #expect(!next.jobs.contains { $0.key.move == "merge" })
        #expect(!log.all.contains { $0.contains("merge not started") })
        try await f.waitForJobs()
        try expectMarkers(f, checksAndCommand: "1")
    }

    private func mark(_ f: StartMovesFixture) throws {
        try SessionWatch(home: f.home).mark(repo: f.repo, number: 7, for: 3600,
            holder: "author-session", now: .now)
    }

    private func expectMarkers(_ f: StartMovesFixture, checksAndCommand: String, agentFix: Bool = false) throws {
        for name in ["check-1", "check-2", agentFix ? "agent" : "command"] {
            // A press reaches checks and command moves, never the agent's environment.
            let expected = name == "agent" ? "absent" : checksAndCommand
            #expect(try String(contentsOf: f.root.appendingPathComponent(name), encoding: .utf8) == expected)
        }
    }

    private func prepareObservedFix(_ f: StartMovesFixture, agentFix: Bool = false) async throws -> JobKey {
        // Real Git lets checks and the move run through the dispatcher's head checks.
        let clone = f.root.appendingPathComponent("clone").path
        let remote = f.root.appendingPathComponent("origin.git").path
        for args in [["clone", remote, clone],
            ["-C", clone, "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
             "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Synthetic"],
            ["-C", clone, "push", "origin", "HEAD:refs/heads/main", "HEAD:refs/pull/7/head"]] {
            let result = try await ProcessRunner().run("/usr/bin/git", args,
                environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], timeout: .seconds(120))
            try #require(result.status == 0, "Local command fixture: \(result.stderr)")
        }
        let result = try await ProcessRunner().run("/usr/bin/git", ["-C", clone, "rev-parse", "HEAD"], timeout: .seconds(10))
        try #require(result.status == 0)
        let head = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try f.editPR { $0["headRefOid"] = head }
        try f.prepareMerge()
        func probe(_ name: String) -> [String] {
            ["/bin/sh", "-c", "printf '%s' \"${BTON_PRESSED-absent}\" > \"$OBSERVE/\(name)\""]
        }
        try f.editFlow { flow in
            var dispatch = flow["dispatch"] as! [String: Any]
            if agentFix {
                dispatch["fix"] = ["agent": "synthetic", "prompt": "Fix", "post": "none"]
            } else {
                dispatch["fix"] = ["command": probe("command")]
            }
            flow["dispatch"] = dispatch
            flow["checks"] = ["beforeSession": [probe("check-1"), probe("check-2")],
                              "beforeMerge": [probe("check-1"), probe("check-2")]]
        }
        var config = try BtonConfig.loadOrCreate(home: f.home)
        if agentFix { config.agents["synthetic"] = AgentTemplate(argv: probe("agent")) }
        config.repos[0].path = clone
        config.repos[0].environment = ["OBSERVE": f.root.path]
        try config.save(to: f.home.configURL)
        let gh = f.root.appendingPathComponent("gh")
        let script = try String(contentsOf: gh, encoding: .utf8)
        let view = """
        if [ "$1" = pr ] && [ "$2" = view ]; then
          echo '{"headRefOid":"\(head)","state":"OPEN"}'; exit 0
        fi
        """
        try script.replacingOccurrences(of: "case \"$2\" in", with: view + "\ncase \"$2\" in")
            .write(to: gh, atomically: true, encoding: .utf8)
        return JobKey(repo: f.repo, item: "pr-7", move: "merge", head: head, round: StartMovesFixture.approvalRound)
    }
}
