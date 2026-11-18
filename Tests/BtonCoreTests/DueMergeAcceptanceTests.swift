@testable import BtonCore
import Foundation
import Testing

struct DueMergeAcceptanceTests {
    @Test(arguments: ["review", "fix", "decide", "custom", "none", "red", "pending", "absent"])
    func onlyADueMergeCanBePressed(state: String) throws {
        var pr = MoveWaitFixture.pr()
        pr.checks = [.init(name: "gate", state: .success)]
        let due = try MoveWaitFixture.flow()
        #expect(DispatchPlanner.mergeCandidate(pr, flow: due, me: "owner", repo: pr.repo) != nil)
        let flow: Flow
        switch state {
        case "red", "pending", "absent":
            flow = due
            pr.checks = state == "absent" ? [] : [.init(name: "gate", state: state == "red" ? .failure : .pending)]
        case "none": flow = try MoveWaitFixture.flow(rules: [])
        default:
            flow = try MoveWaitFixture.flow(rules: [MoveWaitFixture.rule(state, ["approved_current_head"])])
        }
        let move = FlowEngine.move(for: pr, flow: flow)
        if ["none", "pending", "absent"].contains(state) { #expect(move == nil) }
        else if state == "red" { #expect(move?.name == "merge"); #expect(move?.hasDispatch == false); #expect(move?.redChecks == ["gate"]) }
        else { #expect(move?.name == state) }
        #expect(DispatchPlanner.mergeCandidate(pr, flow: flow, me: "owner", repo: pr.repo) == nil)
    }

    @Test func staleStoredMergeDoesNotOverrideFacts() throws {
        var pr = MoveWaitFixture.pr(verdict: "changes")
        let flow = try MoveWaitFixture.flow(rules: [
            MoveWaitFixture.rule("fix", ["latest_review_changes_or_blocked"]),
            MoveWaitFixture.rule("merge", ["approved_current_head"])])
        pr.move = Move(name: "merge", owner: "owner", ownerFromRotation: false, tier: "small", hasDispatch: true)
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "fix")
        #expect(DispatchPlanner.mergeCandidate(pr, flow: flow, me: "owner", repo: pr.repo) == nil)
    }

    @Test func dueMergeMayBeStartedByAuthorInsteadOfItsReviewer() throws {
        let pr = MoveWaitFixture.pr()
        let flow = try MoveWaitFixture.flow(rules: [MoveWaitFixture.rule("merge", ["approved_current_head"], who: "reviewer")])
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.owner == "teammate")
        let candidate = try #require(DispatchPlanner.mergeCandidate(pr, flow: flow, me: "OwNeR", repo: pr.repo))
        #expect(candidate.move.name == "merge")
        #expect(candidate.move.owner == "OwNeR")
        #expect(candidate.move.hasDispatch)
        #expect(candidate.move.tier == move.tier)
    }

    @Test func dueMergeCarriesChecksFromEveryMergeRule() throws {
        var pr = MoveWaitFixture.pr()
        pr.checks = [.init(name: "gate", state: .success)]
        let flow = try MoveWaitFixture.flow(rules: [
            MoveWaitFixture.rule("merge", ["approved_current_head", "checks_green:gate"]),
            MoveWaitFixture.rule("merge", ["label:later", "checks_green:e2e,gate"])])
        let candidate = try #require(DispatchPlanner.mergeCandidate(pr, flow: flow, me: "owner", repo: pr.repo))
        #expect(candidate.requiredChecks == ["gate", "e2e"])
        #expect(candidate.requiredChecks == FlowEngine.requiredChecks(ofMove: "merge", flow: flow))
    }

    @Test func releasePRCannotUseOrdinaryMerge() throws {
        let flow = try MoveWaitFixture.flow(rules: [MoveWaitFixture.rule("merge", ["approved_current_head"])])
        let ordinary = MoveWaitFixture.pr()
        #expect(DispatchPlanner.mergeCandidate(ordinary, flow: flow, me: "owner", repo: ordinary.repo) != nil)
        let release = MoveWaitFixture.pr(release: true)
        #expect(DispatchPlanner.mergeCandidate(release, flow: flow, me: "owner", repo: release.repo) == nil)
    }
}

@Suite(ProcessBound())
struct MergeAskAcceptanceTests {
    private let dropped = "synthetic/project#7: merge not started: the flow does not ask for a merge on it now"

    @Test(arguments: ["author", "reviewer"])
    func pressStartsDueMergeOnThisMac(who: String) async throws {
        let f = try await StartMovesFixture.make()
        defer { f.remove() }
        try f.prepareMerge(who: who)
        let engine = try f.engine()
        let before = await engine.tick()
        #expect(before.jobs.isEmpty)
        #expect(before.openPullRequests.first?.move?.name == "merge")
        #expect(before.openPullRequests.first?.move?.owner == (who == "author" ? "owner" : "teammate"))
        try await engine.runNow(f.mergeKey)
        let after = await engine.tick()
        #expect(after.problem == nil)
        #expect(after.jobs.map(\.key) == [f.mergeKey])
        #expect(after.next.isEmpty)
        try await f.waitForJobs()
    }

    @Test func queuedPressIsDroppedAfterNewerRejectionOnSameHead() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        try f.prepareMerge()
        let other = try f.leases.store("other")
        let held = try RetryLeaseFixture.claimed(await other.claim(f.leases.item, in: f.repo, key: "busy"))
        let log = MoveLog()
        let engine = try f.engine(log: { log.append($0) })
        try await engine.runNow(f.mergeKey)
        let queued = await engine.tick()
        #expect(queued.problem == nil)
        #expect(queued.jobs.isEmpty)
        #expect(queued.next == [Engine.pick(repo: f.repo, item: "pr-7")])
        #expect(queued.openPullRequests.first?.move?.name == "merge")
        try f.reviews(["approve", "changes"])
        try await other.release(held)
        let rejected = await engine.tick()
        #expect(rejected.problem == nil)
        #expect(rejected.openPullRequests.first?.headSha == f.mergeKey.head)
        #expect(rejected.openPullRequests.first?.move?.name == "fix")
        #expect(!rejected.jobs.contains { $0.key.move == "merge" })
        #expect(rejected.next.isEmpty)
        #expect(log.all.contains(dropped))
        try await f.waitForJobs()
        for _ in 0..<2 {
            let later = await engine.tick()
            #expect(later.problem == nil)
            #expect(!later.jobs.contains { $0.key.move == "merge" })
            #expect(later.jobs.contains { $0.key.move == "fix" })
            #expect(later.next.isEmpty)
            try await f.waitForJobs()
        }
    }

    @Test(arguments: ["review", "fix", "red"])
    func pressCannotCreateAMergeThatIsNotDue(state: String) async throws {
        let f = try await StartMovesFixture.make()
        defer { f.remove() }
        try f.prepareMerge(checks: state == "red" ? "gate" : nil, approved: state == "red")
        if state == "fix" { try f.reviews(["changes"]) }
        if state == "red" {
            try f.editPR { $0["headCommit"] = ["nodes": [["commit": ["statusCheckRollup": [
                "contexts": ["totalCount": 1, "nodes": [["__typename": "CheckRun", "name": "gate",
                    "status": "COMPLETED", "conclusion": "FAILURE"]]]]]]]] }
        }
        let log = MoveLog()
        let engine = try f.engine(log: { log.append($0) })
        let before = await engine.tick()
        #expect(before.openPullRequests.first?.move?.name == (state == "red" ? "merge" : state))
        if state == "red" { #expect(before.openPullRequests.first?.move?.redChecks == ["gate"]) }
        try await engine.runNow(f.mergeKey)
        let after = await engine.tick()
        #expect(after.problem == nil)
        #expect(after.jobs.isEmpty)
        #expect(after.next.isEmpty)
        #expect(log.all.contains(dropped))
    }

    @Test(arguments: ["supervisor", "restart", "jobs", "still due"])
    func retryOfAutomaticMergeRechecksWhetherMergeIsDue(entrance: String) async throws {
        let f = try await StartMovesFixture.make()
        defer { f.remove() }
        try f.prepareMerge()
        let store = try JobStore(home: f.home)
        // Persist an automatic failed command exactly as the supervisor fixture does.
        var failed = Job(id: UUID(), key: f.mergeKey, agent: nil,
            startedAt: .now.addingTimeInterval(-60), endedAt: .now.addingTimeInterval(-30),
            status: .failed, detail: "command exited 1", cost: 0)
        failed.flags = [.failed]
        try store.save(failed)
        let mergesBefore = store.all().filter { $0.key.move == "merge" && $0.key.head == failed.key.head }.count
        #expect(mergesBefore == 1)
        let log = MoveLog()
        var engine = try f.engine(log: { log.append($0) })
        if entrance == "jobs" {
            try f.reviews(["approve", "changes"])
            #expect(try await engine.retry(failed.id))
        } else {
            var verdict = Job(id: UUID(), key: JobKey(repo: f.repo, item: "pr-7", move: "supervise", head: failed.key.head),
                agent: "claude", startedAt: .now.addingTimeInterval(-20), endedAt: .now.addingTimeInterval(-10),
                status: .succeeded, cost: 0, supervises: failed.id)
            verdict.verdict = SupervisorVerdict(action: .retry, note: "Retry the transient command failure.")
            try store.save(verdict)
            // Apply the real verdict path while the lease prevents the retry from starting.
            let other = try f.leases.store("other")
            let held = try RetryLeaseFixture.claimed(await other.claim(f.leases.item, in: f.repo, key: "busy"))
            let applied = await engine.tick()
            #expect(applied.problem == nil)
            #expect(applied.openPullRequests.first?.move?.name == "merge")
            #expect(applied.openPullRequests.first?.move?.hasDispatch == true)
            #expect(applied.jobs.filter { $0.key.move == "merge" }.map(\.id) == [failed.id])
            #expect(store.all().first { $0.id == failed.id }?.retry == true)
            #expect(store.all().first { $0.id == verdict.id }?.verdict?.applied == true)
            #expect(store.all().first { $0.id == verdict.id }?.verdict?.outcome == "retried")
            #expect(applied.next == [Engine.pick(repo: f.repo, item: "pr-7")])
            if entrance != "still due" { try f.reviews(["approve", "changes"]) }
            if entrance == "restart" { engine = try f.engine(log: { log.append($0) }) }
            try await other.release(held)
        }
        let first = await engine.tick()
        #expect(first.problem == nil)
        #expect(first.openPullRequests.first?.headSha == failed.key.head)
        #expect(first.openPullRequests.first?.move?.name == (entrance == "still due" ? "merge" : "fix"))
        let runs = first.jobs.filter { $0.key == failed.key && $0.id != failed.id }
        if entrance == "still due" { #expect(runs.count == 1) }
        else {
            #expect(first.jobs.filter { $0.key.move == "merge" && $0.key.head == failed.key.head }.count == mergesBefore)
        }
        #expect(first.next.isEmpty)
        if entrance != "still due" { #expect(log.all.contains(dropped)) }
        try await f.waitForJobs()
        for _ in 0..<2 {
            let later = await engine.tick()
            #expect(later.problem == nil)
            if entrance == "still due" {
                #expect(later.jobs.filter { $0.key == failed.key && $0.id != failed.id }.map(\.id) == runs.map(\.id))
            } else {
                #expect(later.jobs.filter { $0.key.move == "merge" && $0.key.head == failed.key.head }.count == mergesBefore)
            }
            #expect(later.next.isEmpty)
            try await f.waitForJobs()
        }
    }
}
