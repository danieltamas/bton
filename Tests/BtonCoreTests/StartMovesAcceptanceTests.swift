@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct StartMovesAcceptanceTests {
    @Test(arguments: [
        (Optional<Bool>.none, Optional("SyNtHeTiC"), true),
        (nil, "teammate", false), (nil, nil, false),
        (false, "synthetic", false), (true, "teammate", true)
    ])
    func issueWorkDefaultsToTheOwnerAndHonorsAnExplicitChoice(workIssues: Bool?, me: String?, expected: Bool) {
        var repo = WatchedRepo(slug: "synthetic/project", path: nil)
        repo.startMoves = true
        repo.workIssues = workIssues
        #expect(repo.worksIssues(me: me) == expected)
    }

    @Test(arguments: [Optional<Bool>.none, false], [Optional<Bool>.none, false, true])
    func issueWorkRequiresStartMoves(startMoves: Bool?, workIssues: Bool?) {
        var repo = WatchedRepo(slug: "synthetic/project", path: nil)
        repo.startMoves = startMoves
        repo.workIssues = workIssues
        for me in [Optional("synthetic"), "teammate", nil] {
            #expect(!repo.worksIssues(me: me))
        }
    }

    @Test(arguments: ["false", "true", "absent", "null"])
    func configRoundTripsWorkIssues(value: String) throws {
        let field = value == "absent" ? "" : ",\"workIssues\":\(value)"
        let data = Data("""
        {"repos":[{"slug":"synthetic/project","startMoves":true\(field)}],"pollSeconds":60,"maxAgents":2,"agents":{},"schedules":[]}
        """.utf8)
        let config = try JSONDecoder().decode(BtonConfig.self, from: data)
        let expected: Bool? = (value == "absent" || value == "null") ? nil : value == "true"
        #expect(config.repos.first?.workIssues == expected)
        let encoded = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let repo = try #require((object["repos"] as? [[String: Any]])?.first)
        if let expected { #expect(repo["workIssues"] as? Bool == expected) }
        let roundTrip = try JSONDecoder().decode(BtonConfig.self, from: encoded)
        #expect(roundTrip.repos.first?.workIssues == expected)
    }

    @Test(arguments: ["triage", "stage"])
    func issueWorkOffStillReadsIssuesAndStartsPRReview(move: String) async throws {
        let f = try await StartMovesFixture.make(startMoves: true, maxAgents: 8)
        defer { f.remove() }
        let (flow, issues) = try f.prepareIssueWork(move: move)
        var config = try BtonConfig.loadOrCreate(home: f.home)
        config.repos[0].workIssues = false
        try config.save(to: f.home.configURL)
        let engine = try f.engine()
        let snapshot = await engine.tick()
        #expect(snapshot.problem == nil)
        #expect(snapshot.issueAsks.map(\.number) == [8])
        #expect(snapshot.issuesMore == [f.repo])
        #expect(snapshot.jobs.map(\.key.move) == ["review"])
        #expect(snapshot.jobs.map(\.key.item) == ["pr-7"])
        // Prove these inputs offer both kinds of issue work; dispatch must suppress them.
        let ask = try #require(snapshot.issueAsks.first)
        let asked = try #require(issues.first { $0.number == 8 })
        #expect(IssueDecisions.candidate(ask: ask, issue: asked, flow: flow, agents: config.agents,
                                       defaultBranch: "main", me: "owner") != nil)
        #expect(IssueMoves.candidate(issues: issues, flow: flow, pullRequests: [], jobs: [], repo: f.repo,
                                    me: "owner", agents: config.agents)?.key.move == move)
        let staleIssue = try #require(issues.first { $0.number == 10 })
        #expect(Staleness.notice(for: staleIssue, stale: try #require(flow.stale)) != nil)
        try await f.waitForJobs()
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("issue-notice").path))
    }

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
        let f = try await StartMovesFixture.make(startMoves: startMoves, schedule: true, flow: false)
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

    private static let template = Task { try await makeTemplate() }

    private static func makeTemplate() async throws -> Self {
        let leases = try await RetryLeaseFixture.make(template: true)
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
                let result = try await ProcessRunner().run("/usr/bin/git", args, timeout: .seconds(120))
                try #require(result.status == 0, "Local lease setup: \(result.stderr)")
            }
            return f
        } catch { f.remove(); throw error }
    }

    static func make(startMoves: Bool? = nil, conflicting: Bool = false, schedule: Bool = false, flow hasFlow: Bool = true, maxAgents: Int = 2) async throws -> Self {
        let seed = try await template.value
        let root = try GitFixtureCopies.copy(seed.root)
        let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("engine").path])
        let f = Self(leases: RetryLeaseFixture(root: root, item: seed.leases.item), home: home)
        do {
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
            let flowResponse = hasFlow ? """
                cat <<'JSON'
            \(flow)
            JSON
            """ : "echo 'gh: Not Found (HTTP 404)' >&2; exit 1"
            let cases = """
              repos/synthetic/project/contents/.bton/flow.json)
            \(flowResponse)
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

    func prepareIssueWork(move: String) throws -> (Flow, [OpenIssue]) {
        let gh = root.appendingPathComponent("gh")
        let original = try String(contentsOf: gh, encoding: .utf8)
        let oldFlow = try #require(original.components(separatedBy: "\n").first { $0.hasPrefix("{\"version\":") })
        var object = try #require(JSONSerialization.jsonObject(with: Data(oldFlow.utf8)) as? [String: Any])
        object["moves"] = [["move": "review", "when": ["no_review_or_response_newer"], "who": "author"]]
        object["dispatch"] = ["review": ["agent": "synthetic", "prompt": "Review"], move: ["agent": "claude"]]
        object["decide"] = ["by": ["owner"]]
        object["issues"] = [["move": move, "when": ["label:acceptance-work", "no_assignee"]]]
        object["stale"] = ["pingHours": 24, "escalateHours": 48, "escalateTo": "lead"]
        let data = try JSONSerialization.data(withJSONObject: object)
        let flow = try #require(Flow.load(data).flow)
        let issues = [
            IssueAskFixture.issue(body: "@owner can you decide?", number: 8),
            IssueAskFixture.issue(body: "Work on this", number: 9, labels: ["acceptance-work"]),
            IssueAskFixture.issue(body: "Work in progress", author: "owner", number: 10, assignees: ["teammate"])
        ]
        let issueData = try IssueAskFixture.payload(issues, next: "C2")
        try issueData.write(to: root.appendingPathComponent("issues.json"))
        for issue in issues {
            let live: [String: Any] = ["state": "OPEN", "body": issue.body, "comments": [],
                "labels": issue.labels.map { ["name": $0] }, "assignees": issue.assignees.map { ["login": $0] }]
            try JSONSerialization.data(withJSONObject: live)
                .write(to: root.appendingPathComponent("issue-\(issue.number)-live.json"))
        }
        let handler = """
        if [ "$1" = api ] && [ "$2" = graphql ]; then
          case "$*" in *'issues('*) cat "$(dirname "$0")/issues.json"; exit 0 ;; esac
        fi
        if [ "$1" = issue ] && [ "$2" = view ]; then cat "$(dirname "$0")/issue-$3-live.json"; exit 0; fi
        if [ "$1" = issue ] && [ "$2" = comment ]; then touch "$(dirname "$0")/issue-notice"; exit 0; fi
        """
        try original.replacingOccurrences(of: oldFlow, with: String(decoding: data, as: UTF8.self))
            .replacingOccurrences(of: "case \"$2\" in", with: handler + "\ncase \"$2\" in")
            .write(to: gh, atomically: true, encoding: .utf8)
        let agent = root.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        var config = try BtonConfig.loadOrCreate(home: home)
        config.agents["claude"] = AgentTemplate(argv: [agent.path, "-p", "{prompt}"])
        try config.save(to: home.configURL)
        return (flow, try GitHubClient.decodeOpenIssues(issueData, repo: repo).issues)
    }

    func engine() throws -> Engine {
        try Engine(home: home, github: GitHubClient(ghPath: root.appendingPathComponent("gh").path), log: { _ in })
    }

    func waitForJobs() async throws {
        let store = try JobStore(home: home)
        // A fix that pushed nothing reads the head three times, 10 s apart in all, before it ends.
        for _ in 0..<800 {
            if store.all().allSatisfy({ $0.status != .running }) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Fixture jobs did not finish before cleanup")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
