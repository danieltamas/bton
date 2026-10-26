@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct PressedAcceptanceTests {
    @Test func candidateDefaultsToUnpressed() {
        let candidate = DispatchCandidate(target: .branch("main"),
            move: Move(name: "fix", owner: "owner", ownerFromRotation: false, tier: "small", hasDispatch: true),
            key: JobKey(repo: "synthetic/project", item: "pr-7", move: "fix", head: "head"),
            agent: "synthetic", prompt: "Fix", command: nil, postComment: false, timeout: .seconds(5))
        #expect(candidate.pressed == false)
    }

    @Test(arguments: ["merge", "fix", "resolve"])
    func runNowMarksTheDispatchedMove(move: String) async throws {
        let f = try await PressedFixture.make(move: move, startsMoves: false)
        defer { f.remove() }
        let engine = try f.engine()
        let before = await engine.tick()
        #expect(before.problem == nil)
        #expect(before.jobs.isEmpty)
        try await engine.runNow(f.key)
        try await f.observe(engine, expected: "1")
    }

    @Test func explicitRunNextMarksTheMatchingPick() async throws {
        let f = try await PressedFixture.make(move: "fix", startsMoves: false)
        defer { f.remove() }
        let engine = try f.engine()
        await engine.runNext(repo: f.repo, item: "pr-7", pressed: true)
        try await f.observe(engine, expected: "1")
    }

    // Clause 2': supervisor retries and restart restoration only reorder the line.
    @Test func defaultRunNextDoesNotPressTheMatchingPick() async throws {
        let f = try await PressedFixture.make(move: "fix", startsMoves: false)
        defer { f.remove() }
        let engine = try f.engine()
        await engine.runNext(repo: f.repo, item: "pr-7")
        try await f.observe(engine, expected: "absent")
    }

    // Clause 5: a second move of the same PR needs a new person's request.
    @Test func pressIsConsumedByOneMove() async throws {
        let f = try await PressedFixture.make(move: "fix", startsMoves: true)
        defer { f.remove() }
        let engine = try f.engine()
        try await engine.runNow(f.key)
        try await f.observe(engine, expected: "1")
        try f.changeMove(to: "merge")
        for name in ["check-1", "check-2", "release"] {
            try FileManager.default.removeItem(at: f.file(name))
        }
        let later = PressedFixture(root: f.root, home: f.home, head: f.head, move: "merge")
        try await later.observe(engine, expected: "absent")
    }

    @Test func unstartedPressIsDroppedWhenPickLeavesTheLine() async throws {
        let f = try await PressedFixture.make(move: "fix", startsMoves: true)
        defer { f.remove() }
        let engine = try f.engine()
        await engine.runNext(repo: f.repo, item: "pr-8", pressed: true)
        try await f.observe(engine, expected: "absent")
        let snapshot = await engine.tick()
        #expect(!snapshot.next.contains(Engine.pick(repo: f.repo, item: "pr-8")))
        // The previously absent pick becomes runnable, without another press.
        try f.read("gh").replacingOccurrences(of: #""number":7"#, with: #""number":8"#)
            .write(to: f.file("gh"), atomically: true, encoding: .utf8)
        let git = try await ProcessRunner().run("/usr/bin/git",
            ["--git-dir=\(f.root.path)/origin.git", "update-ref", "refs/pull/8/head", f.head], timeout: .seconds(10))
        try #require(git.status == 0)
        for name in ["check-1", "check-2", "release"] {
            try FileManager.default.removeItem(at: f.file(name))
        }
        try await f.observe(engine, expected: "absent", item: "pr-8")
    }

    // Clause 6: exercise persisted cache records through real dispatched checks.
    @Test(arguments: ["pressed", "unpressed", "legacy"], [true, false])
    func passedChecksAreReusedOnlyForTheSamePressKind(priorKind: String, pressed: Bool) async throws {
        let f = try await PressedFixture.make(move: "merge", startsMoves: true)
        defer { f.remove() }
        let flow = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file("flow"))) as? [String: Any])
        let checks = try #require((flow["checks"] as? [String: Any])?["beforeMerge"] as? [[String]])
        var prior = Job(id: UUID(), key: f.key, agent: nil, startedAt: .now.addingTimeInterval(-30),
            endedAt: .now.addingTimeInterval(-20), status: .failed, retry: true)
        if priorKind == "legacy" {
            let data = try JSONSerialization.data(withJSONObject: ["base": f.head, "checks": checks])
            prior.checked = try JSONDecoder().decode(PassedChecks.self, from: data)
            #expect(prior.checked?.pressed == nil)
        } else {
            prior.checked = PassedChecks(base: f.head, checks: checks, pressed: priorKind == "pressed")
        }
        try f.store.save(prior)
        try Data().write(to: f.file("release"))
        let engine = try f.engine()
        if pressed { await engine.runNext(repo: f.repo, item: "pr-7", pressed: true) }
        let snapshot = await engine.tick()
        #expect(snapshot.problem == nil)
        let job = try #require(snapshot.jobs.first { $0.id != prior.id })
        try await f.wait { try f.store.all().contains { $0.id == job.id && $0.status != .running } }
        let ended = try #require(try f.store.all().first { $0.id == job.id })
        #expect(ended.status == .succeeded)
        #expect(ended.checked?.pressed == pressed)
        let reused = priorKind != "legacy" && (priorKind == "pressed") == pressed
        for name in ["check-1", "check-2"] {
            #expect(FileManager.default.fileExists(atPath: f.file(name).path) == !reused)
            if !reused { #expect(try f.read(name) == (pressed ? "1" : "absent")) }
        }
        #expect(try f.read("command") == (pressed ? "1" : "absent"))
    }

    // Clause 7: the process environment must be scrubbed before any child starts.
    @Test(arguments: ["merge", "fix"])
    func inheritedMarkerNeverReachesChecksCommandOrAgent(move: String) async throws {
        let f = try await PressedFixture.make(move: move, startsMoves: true)
        defer { f.remove() }
        let original = getenv("BTON_PRESSED").map { String(cString: $0) }
        defer {
            if let original { setenv("BTON_PRESSED", original, 1) }
            else { unsetenv("BTON_PRESSED") }
        }
        setenv("BTON_PRESSED", "1", 1)
        let engine = try f.engine()
        #expect(getenv("BTON_PRESSED") == nil)
        try await f.observe(engine, expected: "absent")
        if move == "fix" { #expect(try f.read("agent") == "absent") }
    }

    @Test func pressedJobPostsLiteralOneWithoutSavingTheMarker() async throws {
        let f = try await PressedFixture.make(move: "fix", startsMoves: false)
        defer { f.remove() }
        try f.configurePost()
        let engine = try f.engine()
        try await engine.runNow(f.key)
        try await f.observe(engine, expected: "1")
        let posted = try f.read("posted")
        #expect(posted.contains("There is 1 migration"))
        #expect(posted.contains("[REPO_SENTINEL]"))
        #expect(!posted.contains("private-test-value"))
        #expect(!posted.contains("[BTON_PRESSED]"))
    }

    @Test func takeQueuesAPressedMove() async throws {
        let f = try await PressedFixture.make(move: "fix", startsMoves: false)
        defer { f.remove() }
        try f.configureTake()
        let engine = try f.engine()
        let taken = try await engine.take(repo: f.repo, number: 7, from: "teammate")
        #expect(taken.owner == "owner")
        try await f.observe(engine, expected: "1")
    }

    @Test func unrelatedRunNextPickDoesNotMarkAutomaticMove() async throws {
        let f = try await PressedFixture.make(move: "fix", startsMoves: true)
        defer { f.remove() }
        let engine = try f.engine()
        await engine.runNext(repo: "synthetic/other", item: "pr-7")
        await engine.runNext(repo: f.repo, item: "pr-8")
        try await f.observe(engine, expected: "absent")
    }

    @Test(arguments: ["merge", "fix"])
    func automaticSyncLeavesMarkerAbsent(move: String) async throws {
        let f = try await PressedFixture.make(move: move, startsMoves: true)
        defer { f.remove() }
        try await f.observe(f.engine(), expected: "absent")
    }

    @Test func retryMarksAnAutomaticFailedMoveAsPressed() async throws {
        let f = try await PressedFixture.make(move: "fix", startsMoves: true)
        defer { f.remove() }
        try Data().write(to: f.file("fail"))
        try Data().write(to: f.file("release"))
        let engine = try f.engine()
        let first = await engine.tick()
        #expect(first.problem == nil)
        let job = try #require(first.jobs.first)
        try await f.wait { try f.store.all().contains { $0.id == job.id && $0.status == .failed } }
        #expect(try f.read("check-1") == "absent")
        for name in ["fail", "release", "check-1", "check-2"] {
            try? FileManager.default.removeItem(at: f.file(name))
        }
        #expect(try await engine.retry(job.id))
        try await f.observe(engine, expected: "1", excluding: job.id)
    }
}

private struct PressedFixture {
    let root: URL
    let home: BtonHome
    let head: String
    let move: String
    let repo = "synthetic/project"
    var store: JobStore { get throws { try JobStore(home: home) } }
    var key: JobKey { JobKey(repo: repo, item: "pr-7", move: move, head: head) }
    func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func read(_ name: String) throws -> String { try String(contentsOf: file(name), encoding: .utf8) }

    static func make(move: String, startsMoves: Bool) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pressed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let remote = root.appendingPathComponent("origin.git").path
            let clone = root.appendingPathComponent("clone").path
            let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("engine").path])
            try home.prepare()
            let bare = home.url.appendingPathComponent("leases.git").path
            for args in [["init", "--bare", "--initial-branch=main", remote],
                ["clone", remote, clone],
                ["-C", clone, "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Synthetic"],
                ["-C", clone, "push", "origin", "HEAD:refs/heads/main", "HEAD:refs/pull/7/head"],
                ["init", "--bare", bare],
                ["-C", bare, "hash-object", "-w", "-t", "tree", "/dev/null"],
                ["-C", bare, "config", "url.\(remote).insteadOf", "https://github.com/synthetic/project.git"]] {
                let result = try await ProcessRunner().run("/usr/bin/git", args,
                    environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], timeout: .seconds(120))
                try #require(result.status == 0, "Local git setup: \(result.stderr)")
            }
            let result = try await ProcessRunner().run("/usr/bin/git", ["-C", clone, "rev-parse", "HEAD"], timeout: .seconds(10))
            try #require(result.status == 0)
            let head = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let f = Self(root: root, home: home, head: head, move: move)
            // Observe each check, then hold the job while its saved environment still exists.
            let check1 = ["/bin/sh", "-c", "printf '%s' \"${BTON_PRESSED-absent}\" > \"$OBSERVE/check-1\"; while [ ! -f \"$OBSERVE/release\" ]; do sleep 0.02; done; [ ! -f \"$OBSERVE/fail\" ]"]
            let check2 = ["/bin/sh", "-c", "printf '%s' \"${BTON_PRESSED-absent}\" > \"$OBSERVE/check-2\""]
            let command = ["/bin/sh", "-c", "printf '%s' \"${BTON_PRESSED-absent}\" > \"$OBSERVE/command\""]
            let flow: [String: Any] = ["version": 1, "base": "main",
                "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
                "reviews": [String: String](), "fixed": "Fixed:",
                "moves": [["move": move, "when": ["no_review_or_response_newer"], "who": "author"]],
                "dispatch": ["fix": ["agent": "synthetic", "prompt": "Fix"],
                             "resolve": ["agent": "synthetic", "prompt": "Resolve"],
                             "merge": ["command": command]],
                "checks": ["beforeSession": [check1, check2], "beforeMerge": [check1, check2]]]
            try JSONSerialization.data(withJSONObject: flow).write(to: f.file("flow"))
            // A small real process stands in for the configured agent.
            let agent = ["/bin/sh", "-c", "printf '%s' \"${BTON_PRESSED-absent}\" > \"$OBSERVE/agent\""]
            var watched = WatchedRepo(slug: f.repo, path: clone)
            watched.startMoves = startsMoves
            watched.environment = ["OBSERVE": root.path, "REPO_SENTINEL": "private-test-value"]
            try BtonConfig(repos: [watched], pollSeconds: 60, maxAgents: 2,
                agents: ["synthetic": AgentTemplate(argv: agent)], schedules: []).save(to: home.configURL)
            try PriceList(models: [:], updatedAt: .now).save(home: home)
            let script = """
            #!/bin/sh
            set -eu
            cd "${0%/*}"
            if [ "$1" = pr ] && [ "$2" = view ]; then
              echo '{"headRefOid":"\(head)","state":"OPEN"}'; exit 0
            fi
            if [ "$1" != api ]; then
              if [ "$2" = list ]; then echo '[]'; fi
              exit 0
            fi
            case "$2" in
              repos/synthetic/project/contents/.bton/flow.json) cat flow ;;
              graphql)
                cat <<'JSON'
            {"data":{"viewer":{"login":"owner"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":7,"title":"Synthetic","url":"https://example.invalid/pr/7","isDraft":false,"headRefOid":"\(head)","headRefName":"feature","baseRefName":"main","body":"","updatedAt":"2026-10-19T12:00:00Z","mergeable":"MERGEABLE","authorAssociation":"OWNER","author":{"login":"owner"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[]}}]}}}}
            JSON
                ;;
              list) echo '[]' ;;
              repos/synthetic/project/git/ref/*)
                ref="refs/${2#repos/synthetic/project/git/ref/}"
                if sha=$(/usr/bin/git --git-dir=origin.git rev-parse --verify "$ref" 2>/dev/null); then
                  printf '{"object":{"sha":"%s"}}' "$sha"
                else echo 'HTTP 404' >&2; exit 1; fi ;;
              repos/synthetic/project/git/commits/*)
                sha="${2##*/}"
                message=$(/usr/bin/git --git-dir=origin.git show -s --format=%s "$sha")
                message=${message//\\\\/\\\\\\\\}
                message=${message//\\\"/\\\\\\\"}
                printf '{"message":"%s"}' "$message" ;;
              *) exit 2 ;;
            esac
            """
            try script.write(to: f.file("gh"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.file("gh").path)
            return f
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func changeMove(to move: String) throws {
        var flow = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file("flow"))) as? [String: Any])
        flow["moves"] = [["move": move, "when": ["no_review_or_response_newer"], "who": "author"]]
        try JSONSerialization.data(withJSONObject: flow).write(to: file("flow"))
    }

    func configurePost() throws {
        var flow = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file("flow"))) as? [String: Any])
        flow["reviews"] = ["small": [["heading": "## Review:"]]]
        var dispatch = try #require(flow["dispatch"] as? [String: Any])
        dispatch["fix"] = ["agent": "synthetic", "prompt": "Fix", "post": "comment"]
        flow["dispatch"] = dispatch
        try JSONSerialization.data(withJSONObject: flow).write(to: file("flow"))
        var config = try BtonConfig.loadOrCreate(home: home)
        config.agents["synthetic"] = AgentTemplate(argv: ["/bin/sh", "-c",
            "printf '%s\\n' '## Review: approve (head \(head))' 'There is 1 migration private-test-value'"])
        try config.save(to: home.configURL)
        let handler = #"""
        if [ "$1" = pr ] && [ "$2" = comment ]; then cp "$7" posted; exit 0; fi
        """#
        try read("gh").replacingOccurrences(of: "if [ \"$1\" != api ]; then",
            with: handler + "\nif [ \"$1\" != api ]; then")
            .write(to: file("gh"), atomically: true, encoding: .utf8)
    }

    func configureTake() throws {
        var flow = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file("flow"))) as? [String: Any])
        flow["moves"] = [["move": "fix", "when": ["no_review_or_response_newer"], "who": "assignee"]]
        try JSONSerialization.data(withJSONObject: flow).write(to: file("flow"))
        var script = try read("gh")
        let line = try #require(script.components(separatedBy: "\n").first { $0.hasPrefix("{\"data\":") })
        let payload = line.replacingOccurrences(of: #""assignees":{"nodes":[]}"#,
            with: #""assignees":{"nodes":[{"login":"teammate"}]}"#)
        try payload.write(to: file("prs"), atomically: true, encoding: .utf8)
        script = script.replacingOccurrences(of: "cat <<'JSON'\n" + line + "\nJSON", with: "cat prs")
        let assign = #"""
        if [ "$1" = pr ] && [ "$2" = edit ] && [ "${6-}" = --add-assignee ]; then
          /usr/bin/sed 's/"login":"teammate"/"login":"owner"/g' prs > prs.next
          mv prs.next prs
          exit 0
        fi
        """#
        script = script.replacingOccurrences(of: "if [ \"$1\" != api ]; then", with: assign + "\nif [ \"$1\" != api ]; then")
        try script.write(to: file("gh"), atomically: true, encoding: .utf8)
    }

    func engine() throws -> Engine {
        try Engine(home: home, github: GitHubClient(ghPath: file("gh").path), log: { _ in })
    }

    func wait(_ condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(try condition(), "Timed out waiting for the real job boundary")
    }

    func observe(_ engine: Engine, expected: String, excluding: UUID? = nil, item: String = "pr-7") async throws {
        let snapshot = await engine.tick()
        #expect(snapshot.problem == nil)
        let job = try #require(snapshot.jobs.first { $0.id != excluding && $0.key.item == item && $0.key.move == move })
        #expect(job.key == JobKey(repo: repo, item: item, move: move, head: head))
        defer { try? Data().write(to: file("release")) }
        do {
            try await wait { FileManager.default.fileExists(atPath: file("check-1").path) }
            #expect(try read("check-1") == expected)
            let saved = try store.startedEnvironment(job.id)
            #expect(saved == ["OBSERVE": root.path, "REPO_SENTINEL": "private-test-value"])
            #expect(saved["BTON_PRESSED"] == nil)
            #expect(DispatchPlanner.redact("There is 1 migration", environment: saved) == "There is 1 migration")
        }
        try Data().write(to: file("release"))
        try await wait { try store.all().contains { $0.id == job.id && $0.status != .running } }
        let ended = try #require(try store.all().first { $0.id == job.id })
        if move == "resolve" {
            // The no-op agent proves dispatch/checks, but deliberately pushes no resolution.
            #expect(ended.status == .failed)
            #expect(ended.detail?.contains("pushed nothing") == true)
        } else {
            #expect(ended.status == .succeeded, "\(ended.detail ?? "")")
        }
        if move == "merge" { #expect(try read("command") == expected) }
        #expect(try read("check-2") == expected)
    }
}
