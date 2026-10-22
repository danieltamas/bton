@testable import BtonCore
import Foundation
import Testing

struct StartMovesAcceptanceTests {
    @Test(arguments: [Optional<Bool>.none, false])
    func syncOnlyStillReportsMyFlowMove(startMoves: Bool?) async throws {
        let f = try await StartMovesFixture.make(startMoves: startMoves)
        defer { f.remove() }
        let engine = try f.engine()
        let snapshot = await engine.tick()
        #expect(snapshot.problem == nil)
        #expect(snapshot.jobs.isEmpty)
        let pr = try #require(snapshot.openPullRequests.first)
        #expect(snapshot.openPullRequests.count == 1)
        #expect(pr.move?.name == "fix")
        #expect(pr.move?.owner == "owner")
        #expect(pr.move?.hasDispatch == true)
    }

    @Test(arguments: [Optional<Bool>.none, false])
    func syncOnlyStartsDueSchedule(startMoves: Bool?) async throws {
        let f = try await StartMovesFixture.make(startMoves: startMoves, schedule: true)
        defer { f.remove() }
        let snapshot = try await f.engine().tick()
        #expect(snapshot.problem == nil)
        #expect(snapshot.jobs.map(\.key.move) == ["schedule"])
        #expect(snapshot.jobs.map(\.key.item) == ["schedule-1"])
        try await f.waitForJobs()
    }

    @Test(arguments: [Optional<Bool>.none, false])
    func runNextStartsFlowMoveInSyncOnlyRepo(startMoves: Bool?) async throws {
        let f = try await StartMovesFixture.make(startMoves: startMoves)
        defer { f.remove() }
        let engine = try f.engine()
        #expect(await engine.tick().jobs.isEmpty)
        await engine.runNext(repo: f.repo, item: "pr-7")
        let snapshot = await engine.tick()
        #expect(snapshot.problem == nil)
        #expect(snapshot.jobs.map(\.key) == [f.key("fix")])
        #expect(snapshot.next.isEmpty)
        try await f.waitForJobs()
    }

    @Test(arguments: [Optional<Bool>.none, false])
    func syncOnlyConflictsWaitForExplicitResolve(startMoves: Bool?) async throws {
        let f = try await StartMovesFixture.make(startMoves: startMoves, conflicting: true)
        defer { f.remove() }
        let engine = try f.engine()
        let before = await engine.tick()
        #expect(before.problem == nil)
        #expect(before.openPullRequests.first?.conflicting == true)
        #expect(before.jobs.isEmpty)
        try await engine.runNow(f.key("resolve"))
        let after = await engine.tick()
        #expect(after.problem == nil)
        #expect(after.jobs.map(\.key) == [f.key("resolve")])
        try await f.waitForJobs()
    }

    @Test func enabledRepoStartsFlowMove() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let snapshot = try await f.engine().tick()
        #expect(snapshot.problem == nil)
        #expect(snapshot.jobs.map(\.key) == [f.key("fix")])
        try await f.waitForJobs()
    }

    @Test(arguments: [Optional<Bool>.none, false, true])
    func busyMergeWaitsWithoutFallingBackToFlow(startMoves: Bool?) async throws {
        let f = try await StartMovesFixture.make(startMoves: startMoves)
        defer { f.remove() }
        let other = try f.leases.store("other")
        let held = try RetryLeaseFixture.claimed(await other.claim(f.leases.item, in: f.repo, key: "schedule-agent"))
        #expect(!held.record.hasRun(f.key("merge").description))
        let engine = try f.engine()
        try await engine.runNow(f.key("merge"))
        for _ in 0..<2 {
            let busy = await engine.tick()
            #expect(busy.problem == nil)
            #expect(busy.jobs.isEmpty)
            #expect(busy.next == ["synthetic/project#pr-7"])
        }
        try await other.release(held)
        let free = await engine.tick()
        #expect(free.problem == nil)
        #expect(free.jobs.map(\.key) == [f.key("merge")])
        #expect(free.next.isEmpty)
        try await f.waitForJobs()
    }

    @Test func mergeInRemoteHistoryIsDropped() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let other = try f.leases.store("other")
        let merge = try RetryLeaseFixture.claimed(await other.claim(f.leases.item, in: f.repo,
            key: f.key("merge").description))
        try await other.release(merge)
        let later = try RetryLeaseFixture.claimed(await other.claim(f.leases.item, in: f.repo, key: "later-move"))
        try await other.release(later)
        #expect(later.record.done?.contains(f.key("merge").description) == true)
        let engine = try f.engine()
        try await engine.runNow(f.key("merge"))
        let ran = await engine.tick()
        #expect(ran.problem == nil)
        #expect(ran.jobs.isEmpty)
        #expect(ran.next.isEmpty)
        // The next sync must resume the flow, proving the Merge override was discarded.
        let resumed = await engine.tick()
        #expect(resumed.problem == nil)
        #expect(resumed.jobs.map(\.key) == [f.key("fix")])
        try await f.waitForJobs()
    }

    @Test(arguments: [false, true])
    func invalidBusyMergeCannotStartAnythingInSyncOnlyRepo(conflicts: Bool) async throws {
        let f = try await StartMovesFixture.make()
        defer { f.remove() }
        let other = try f.leases.store("other")
        let held = try RetryLeaseFixture.claimed(await other.claim(f.leases.item, in: f.repo, key: "schedule-agent"))
        let engine = try f.engine()
        try await engine.runNow(f.key("merge"))
        let busy = await engine.tick()
        #expect(busy.problem == nil)
        #expect(busy.jobs.isEmpty)
        #expect(busy.next == ["synthetic/project#pr-7"])
        try f.updatePRs(head: conflicts ? "same-head" : "new-head", conflicting: conflicts)
        try await other.release(held)
        for _ in 0..<2 {
            let invalidated = await engine.tick()
            #expect(invalidated.problem == nil)
            #expect(invalidated.jobs.isEmpty)
            #expect(invalidated.next.isEmpty)
        }
    }

    @Test func syncOnlyRunNextAlreadyRunElsewhereLeavesQueue() async throws {
        let f = try await StartMovesFixture.make()
        defer { f.remove() }
        let other = try f.leases.store("other")
        let ran = try RetryLeaseFixture.claimed(await other.claim(f.leases.item, in: f.repo,
            key: f.key("fix").description))
        try await other.release(ran)
        let engine = try f.engine()
        await engine.runNext(repo: f.repo, item: "pr-7")
        for _ in 0..<2 {
            let snapshot = await engine.tick()
            #expect(snapshot.problem == nil)
            #expect(snapshot.jobs.isEmpty)
            #expect(snapshot.next.isEmpty)
        }
    }

    @Test func invalidMergeLosesPriorityButAutomaticFlowContinues() async throws {
        let f = try await StartMovesFixture.make(startMoves: true, maxAgents: 1)
        defer { f.remove() }
        let other = try f.leases.store("other")
        let held = try RetryLeaseFixture.claimed(await other.claim(f.leases.item, in: f.repo, key: "schedule-agent"))
        let engine = try f.engine()
        try await engine.runNow(f.key("merge"))
        let busy = await engine.tick()
        #expect(busy.jobs.isEmpty)
        #expect(busy.next == ["synthetic/project#pr-7"])
        try f.updatePRs(head: "new-head", includeOlder: true)
        try await other.release(held)
        let first = await engine.tick()
        #expect(first.problem == nil)
        #expect(first.next.isEmpty)
        #expect(first.jobs.map(\.key.item) == ["pr-6"])
        #expect(first.jobs.map(\.key.move) == ["fix"])
        try await f.waitForJobs()
        let second = await engine.tick()
        #expect(second.problem == nil)
        #expect(second.jobs.contains { $0.key == JobKey(repo: f.repo, item: "pr-7", move: "fix", head: "new-head") })
        #expect(!second.jobs.contains { $0.key.move == "merge" })
        try await f.waitForJobs()
    }

    @Test(arguments: ["false", "true", "absent", "null"])
    func configRoundTripsStartMoves(value: String) throws {
        let field = value == "absent" ? "" : ",\"startMoves\":\(value)"
        let data = Data("""
        {"repos":[{"slug":"synthetic/project"\(field)}],"pollSeconds":60,"maxAgents":2,"agents":{},"schedules":[]}
        """.utf8)
        let config = try JSONDecoder().decode(BtonConfig.self, from: data)
        let expected: Bool? = (value == "absent" || value == "null") ? nil : value == "true"
        let decoded = try #require(config.repos.first)
        #expect(decoded.startMoves == expected)
        #expect(decoded.startsMoves == (value == "true"))
        let roundTrip = try JSONDecoder().decode(BtonConfig.self, from: JSONEncoder().encode(config))
        #expect(roundTrip.repos.first?.startMoves == expected)
        #expect(roundTrip.repos.first?.startsMoves == (value == "true"))
    }
}

struct StartMovesFixture {
    let leases: RetryLeaseFixture
    let home: BtonHome
    var repo: String { leases.repo }
    var root: URL { leases.root }
    func key(_ move: String) -> JobKey { JobKey(repo: repo, item: "pr-7", move: move, head: "same-head") }

    static func make(startMoves: Bool? = nil, conflicting: Bool = false, schedule: Bool = false, maxAgents: Int = 2) async throws -> Self {
        let leases = try await RetryLeaseFixture.make()
        let home = BtonHome(environment: ["BTON_HOME": leases.root.appendingPathComponent("engine").path])
        let f = Self(leases: leases, home: home)
        do {
            try home.prepare()
            // Engine creates its own LeaseStore. Redirect only its bare repo's URL to the
            // existing local lease fixture; no global Git settings or network are involved.
            let bare = home.url.appendingPathComponent("leases.git").path
            for args in [["init", "--bare", bare],
                         ["-C", bare, "hash-object", "-w", "-t", "tree", "/dev/null"],
                         ["-C", bare, "config", "url.\(f.root.appendingPathComponent("origin.git").path).insteadOf",
                          "https://github.com/synthetic/project.git"]] {
                let result = try await ProcessRunner().run("/usr/bin/git", args, timeout: .seconds(20))
                try #require(result.status == 0, "Local lease setup: \(result.stderr)")
            }
            var watched = WatchedRepo(slug: f.repo, path: f.root.path)
            watched.startMoves = startMoves
            let schedules = schedule ? [ScheduleEntry(name: "Synthetic", everyMinutes: 60, enabled: true,
                repo: f.repo, agent: "synthetic", prompt: "Synthetic", number: 1)] : []
            try BtonConfig(repos: [watched], pollSeconds: 60, maxAgents: maxAgents,
                agents: ["synthetic": AgentTemplate(argv: ["/usr/bin/true"])], schedules: schedules).save(to: home.configURL)
            try PriceList(models: [:], updatedAt: .now).save(home: home)
            let gh = f.root.appendingPathComponent("gh")
            let old = try String(contentsOf: gh, encoding: .utf8)
            let flow = #"{"version":1,"base":"main","tier":{"marker":"Tier:","values":["small"],"default":"small"},"reviews":{},"fixed":"Fixed:","moves":[{"move":"fix","when":["no_review_or_response_newer"],"who":"author"}],"dispatch":{"fix":{"agent":"synthetic","prompt":"Fix"},"resolve":{"agent":"synthetic","prompt":"Resolve"},"merge":{"command":["/usr/bin/true"]}}}"#
            let cases = """
              repos/synthetic/project/contents/.bton/flow.json)
                cat <<'JSON'
            \(flow)
            JSON
                ;;
              graphql)
                cat <<'JSON'
            {"data":{"viewer":{"login":"owner"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":7,"title":"Synthetic","url":"https://example.invalid/pr/7","isDraft":false,"headRefOid":"same-head","headRefName":"feature","baseRefName":"main","body":"","updatedAt":"2026-10-19T12:00:00Z","mergeable":"\(conflicting ? "CONFLICTING" : "MERGEABLE")","authorAssociation":"OWNER","author":{"login":"owner"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[]}}]}}}}
            JSON
                ;;
              list) echo '[]' ;;
            """
            try old.replacingOccurrences(of: "case \"$2\" in", with: "case \"$2\" in\n\(cases)")
                .write(to: gh, atomically: true, encoding: .utf8)
            return f
        } catch { f.remove(); throw error }
    }

    func updatePRs(head: String, conflicting: Bool = false, includeOlder: Bool = false) throws {
        let gh = root.appendingPathComponent("gh")
        let script = try String(contentsOf: gh, encoding: .utf8)
        let line = try #require(script.components(separatedBy: "\n").first { $0.hasPrefix("{\"data\":") })
        var payload = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        var data = try #require(payload["data"] as? [String: Any])
        var repository = try #require(data["repository"] as? [String: Any])
        var prs = try #require(repository["pullRequests"] as? [String: Any])
        var pr = try #require((prs["nodes"] as? [[String: Any]])?.first)
        pr["headRefOid"] = head
        pr["mergeable"] = conflicting ? "CONFLICTING" : "MERGEABLE"
        var nodes = [pr]
        if includeOlder {
            var older = pr
            older["number"] = 6
            older["headRefOid"] = "older-head"
            nodes.append(older)
        }
        prs["nodes"] = nodes
        repository["pullRequests"] = prs
        data["repository"] = repository
        payload["data"] = data
        let replacement = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        try script.replacingOccurrences(of: line, with: replacement).write(to: gh, atomically: true, encoding: .utf8)
    }

    func engine() throws -> Engine {
        try Engine(home: home, github: GitHubClient(ghPath: root.appendingPathComponent("gh").path), log: { _ in })
    }

    func waitForJobs() async throws {
        let store = try JobStore(home: home)
        for _ in 0..<200 {
            if store.all().allSatisfy({ $0.status != .running }) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Fixture jobs did not finish before cleanup")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
