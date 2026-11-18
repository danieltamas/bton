@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct CleanMergeEngineAcceptanceTests {
    @Test func syncAndReadListsCarryCleanApprovalAndStartMergeAtHead() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let graph = try await CleanMergeFixture.make()
        defer { graph.remove() }
        try prepare(f, graph)
        let engine = try f.engine()
        let listed = try #require(await engine.readLists())
        #expect(listed.problem == nil)
        #expect(listed.openPullRequests.first?.move?.name == "merge")
        let synced = await engine.tick()
        #expect(synced.problem == nil)
        let pr = try #require(synced.openPullRequests.first)
        #expect(pr.author == "owner")
        #expect(pr.move?.name == "merge")
        #expect(pr.move?.owner == "owner")
        let job = try #require(synced.jobs.first)
        #expect(synced.jobs.count == 1)
        #expect(job.key.move == "merge")
        #expect(job.key.head == graph.head)
        try await f.waitForJobs()
        #expect(try String(contentsOf: f.root.appendingPathComponent("merged-head"), encoding: .utf8) == graph.head)
    }

    @Test func refusedCarryLogsOnceAndReadListsIsSilent() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let graph = try await CleanMergeFixture.make(conflict: true)
        defer { graph.remove() }
        try prepare(f, graph)
        let log = MoveLog()
        let engine = try f.engine(log: { log.append($0) })
        let line = warning(f, graph, reason: "\(CleanMergeFixture.short(graph.head)) resolves a conflict by hand")
        // A list read before any sync must not consume or produce the diagnostic.
        let initial = try #require(await engine.readLists())
        #expect(initial.openPullRequests.first?.move?.name == "review")
        #expect(!log.all.contains(line))
        for _ in 0..<2 {
            let synced = await engine.tick()
            #expect(synced.problem == nil)
            #expect(synced.openPullRequests.first?.move?.name == "review")
            #expect(synced.openPullRequests.first?.move?.owner == "teammate")
            #expect(synced.jobs.isEmpty)
            #expect(log.all.filter { $0 == line }.count == 1)
            let listed = try #require(await engine.readLists())
            #expect(listed.openPullRequests.first?.move?.name == "review")
            #expect(log.all.filter { $0 == line }.count == 1)
        }
    }

    @Test func approvalOfTheRefusedHeadItselfStartsMerge() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let graph = try await CleanMergeFixture.make(conflict: true)
        defer { graph.remove() }
        try prepare(f, graph)
        let engine = try f.engine()
        let before = await engine.tick()
        #expect(before.openPullRequests.first?.move?.name == "review")
        #expect(before.jobs.isEmpty)
        try f.reviews(["approve"], head: graph.head)
        let after = await engine.tick()
        #expect(after.problem == nil)
        #expect(after.openPullRequests.first?.move?.name == "merge")
        #expect(after.jobs.count == 1)
        #expect(after.jobs.first?.key.move == "merge")
        #expect(after.jobs.first?.key.head == graph.head)
        try await f.waitForJobs()
        #expect(try String(contentsOf: f.root.appendingPathComponent("merged-head"), encoding: .utf8) == graph.head)
    }

    @Test func missingWatchedCloneAsksForReviewAndLogsReason() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let graph = try await CleanMergeFixture.make()
        defer { graph.remove() }
        try prepare(f, graph, watched: false)
        let log = MoveLog()
        let engine = try f.engine(log: { log.append($0) })
        let synced = await engine.tick()
        #expect(synced.problem == nil)
        #expect(synced.openPullRequests.first?.move?.name == "review")
        #expect(synced.jobs.isEmpty)
        let line = warning(f, graph, reason:
            "could not check \(CleanMergeFixture.short(graph.head)): no clone of the repo on this Mac")
        #expect(log.all.filter { $0 == line }.count == 1)
    }

    // Threat 12: carry must not bypass the existing head-bound command guard.
    @Test func headMovingAfterCarryCannotRunMergeCommand() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let graph = try await CleanMergeFixture.make()
        defer { graph.remove() }
        try prepare(f, graph, liveHead: graph.a)
        let engine = try f.engine()
        let synced = await engine.tick()
        #expect(synced.problem == nil)
        #expect(synced.openPullRequests.first?.move?.name == "merge")
        #expect(synced.jobs.count == 1)
        #expect(synced.jobs.first?.key.head == graph.head)
        try await f.waitForJobs()
        let job = try #require(try JobStore(home: f.home).all().first)
        #expect(job.status == .failed)
        #expect((job.detail ?? "").contains("head moved"))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("merged-head").path))
    }

    @Test func changedRefusalTextForSameHeadGetsItsOwnLogLine() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let graph = try await CleanMergeFixture.make(conflict: true)
        defer { graph.remove() }
        try prepare(f, graph, watched: false)
        let log = MoveLog()
        let engine = try f.engine(log: { log.append($0) })
        let first = await engine.tick()
        #expect(first.jobs.isEmpty)
        let missing = warning(f, graph, reason:
            "could not check \(CleanMergeFixture.short(graph.head)): no clone of the repo on this Mac")
        #expect(log.all.filter { $0 == missing }.count == 1)
        var config = try BtonConfig.loadOrCreate(home: f.home)
        config.repos[0].path = graph.clone.path
        try config.save(to: f.home.configURL)
        let conflict = warning(f, graph, reason: "\(CleanMergeFixture.short(graph.head)) resolves a conflict by hand")
        for _ in 0..<2 {
            let next = await engine.tick()
            #expect(next.jobs.isEmpty)
            #expect(log.all.filter { $0 == missing }.count == 1)
            #expect(log.all.filter { $0 == conflict }.count == 1)
        }
    }

    @Test func newRefusedHeadGetsItsOwnLogLine() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let graph = try await CleanMergeFixture.make(conflict: true)
        defer { graph.remove() }
        try prepare(f, graph)
        let log = MoveLog()
        let engine = try f.engine(log: { log.append($0) })
        let first = await engine.tick()
        #expect(first.jobs.isEmpty)
        let old = warning(f, graph, reason: "\(CleanMergeFixture.short(graph.head)) resolves a conflict by hand")
        #expect(log.all.filter { $0 == old }.count == 1)
        let tree = try await CleanMergeFixture.git(graph.clone, ["rev-parse", "\(graph.head)^{tree}"])
        let head = try await graph.chosenCommit(tree: tree, parents: [graph.a, graph.base1])
        #expect(head != graph.head)
        try f.editPR { pr in
            let node = graph.node(head: head)
            pr["headRefOid"] = node["headRefOid"]
            pr["commits"] = node["commits"]
        }
        let new = old.replacingOccurrences(of: CleanMergeFixture.short(graph.head), with: CleanMergeFixture.short(head))
        for _ in 0..<2 {
            let next = await engine.tick()
            #expect(next.jobs.isEmpty)
            #expect(next.openPullRequests.first?.move?.name == "review")
            #expect(log.all.filter { $0 == old }.count == 1)
            #expect(log.all.filter { $0 == new }.count == 1)
        }
    }

    private func warning(_ f: StartMovesFixture, _ graph: CleanMergeFixture, reason: String) -> String {
        "\(f.repo)#7: the approval of \(CleanMergeFixture.short(graph.a)) does not carry to \(CleanMergeFixture.short(graph.head)): \(reason)"
    }

    private func prepare(_ f: StartMovesFixture, _ graph: CleanMergeFixture,
                         watched: Bool = true, liveHead: String? = nil) throws {
        try f.prepareMerge()
        try f.editPR { pr in
            let node = graph.node()
            for key in ["headRefOid", "baseRefName", "baseRef", "commits", "files"] { pr[key] = node[key] }
        }
        try f.reviews(["approve"], head: graph.a)
        try f.editFlow { flow in
            var dispatch = flow["dispatch"] as! [String: Any]
            dispatch["merge"] = ["command": ["/bin/sh", "-c", "printf '%s' '{head}' > \"$OBSERVE/merged-head\""]]
            flow["dispatch"] = dispatch
        }
        var config = try BtonConfig.loadOrCreate(home: f.home)
        config.repos[0].path = watched ? graph.clone.path : nil
        config.repos[0].environment = ["OBSERVE": f.root.path]
        try config.save(to: f.home.configURL)
        let gh = f.root.appendingPathComponent("gh")
        let script = try String(contentsOf: gh, encoding: .utf8)
        let view = """
        if [ "$1" = pr ] && [ "$2" = view ]; then
          echo '{"headRefOid":"\(liveHead ?? graph.head)","state":"OPEN"}'; exit 0
        fi
        """
        try script.replacingOccurrences(of: "case \"$2\" in", with: view + "\ncase \"$2\" in")
            .write(to: gh, atomically: true, encoding: .utf8)
    }
}
