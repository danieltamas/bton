@testable import BtonCore
import Testing
import Foundation

@Suite(ProcessBound())
struct PauseAcceptanceTests {
    @Test func missingPauseKeyDecodesAsUnpaused() throws {
        let json = Data(#"{"repos":[],"pollSeconds":60,"maxAgents":2,"agents":{},"schedules":[]}"#.utf8)
        let config = try JSONDecoder().decode(BtonConfig.self, from: json)
        #expect(config.paused == nil)
        #expect(!config.isPaused)
        #expect(!Engine.Snapshot().paused)
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func pauseSettingSurvivesSaveAndLoad(paused: Bool?) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pause-config-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        var config = BtonConfig.initial
        config.paused = paused
        #expect(config.isPaused == (paused == true))
        try config.save(to: home.configURL)
        let loaded = try BtonConfig.loadOrCreate(home: home)
        #expect(loaded.paused == paused)
        #expect(loaded.isPaused == (paused == true))
    }

    @Test(arguments: [true, false])
    func pausedTickReadsNothingAndStartsNothing(dispatching: Bool) async throws {
        let f = try await PauseAcceptanceFixture.make()
        defer { f.remove() }
        try f.setPaused(true)
        let engine = try f.engine()
        let snapshot = await engine.tick(dispatching: dispatching)
        #expect(snapshot.paused)
        #expect(snapshot.problem == nil)
        #expect(snapshot.openPullRequests.isEmpty)
        #expect(!snapshot.jobs.contains { $0.status == .running })
        #expect(try f.calls().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.file("agent-pid").path))
    }

    @Test(arguments: [nil, false] as [Bool?])
    func pausingCancelsLiveAgentAndUnpausingReadsAgain(resumedPause: Bool?) async throws {
        let f = try await PauseAcceptanceFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        let started = await engine.tick()
        #expect(!started.paused)
        #expect(started.problem == nil)
        let job = try #require(started.jobs.first { $0.key == f.key && $0.status == .running })
        try await f.wait {
            guard let text = try? String(contentsOf: f.file("agent-pid"), encoding: .utf8) else { return false }
            return Int32(text) != nil
        }
        let pid = try #require(Int32(try String(contentsOf: f.file("agent-pid"), encoding: .utf8)))
        #expect(try await f.agentIsAlive(pid))
        try f.setPaused(true)
        // Discard the calls that started the job; every later invocation is observable too.
        try Data().write(to: f.file("gh-calls"))
        let paused = await engine.tick()
        #expect(paused.paused)
        #expect(paused.problem == nil)
        #expect(paused.openPullRequests.isEmpty)
        #expect(!paused.jobs.contains { $0.status == .running })
        try await f.wait { try f.store.all().contains { $0.id == job.id && $0.status == .cancelled } }
        let ended = try #require(try f.store.all().first { $0.id == job.id })
        #expect(ended.status == .cancelled)
        #expect(ended.detail == "paused")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while try await f.agentIsAlive(pid), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try await f.agentIsAlive(pid) == false)
        #expect(!FileManager.default.fileExists(atPath: f.file("release").path))
        #expect(try f.calls().isEmpty)
        try f.setPaused(resumedPause)
        let resumed = await engine.tick(dispatching: false)
        #expect(!resumed.paused)
        #expect(resumed.problem == nil)
        #expect(!resumed.openPullRequests.isEmpty)
        #expect(try !f.calls().isEmpty)
    }
}

private struct PauseAcceptanceFixture {
    let root: URL
    let home: BtonHome
    let head: String
    let repo = "synthetic/project"
    var store: JobStore { get throws { try JobStore(home: home) } }
    var key: JobKey { JobKey(repo: repo, item: "pr-7", move: "fix", head: head) }
    func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    func remove() {
        // On a failed assertion, let the waiting agent exit before removing its directory.
        try? Data().write(to: file("release"))
        try? FileManager.default.removeItem(at: root)
    }

    func calls() throws -> String {
        guard FileManager.default.fileExists(atPath: file("gh-calls").path) else { return "" }
        return try String(contentsOf: file("gh-calls"), encoding: .utf8)
    }

    func setPaused(_ paused: Bool?) throws {
        var config = try BtonConfig.loadOrCreate(home: home)
        config.paused = paused
        try config.save(to: home.configURL)
    }

    func engine() throws -> Engine {
        try Engine(home: home, github: GitHubClient(ghPath: file("gh").path), log: { _ in })
    }

    func agentIsAlive(_ pid: Int32) async throws -> Bool {
        let result = try await ProcessRunner().run("/bin/kill", ["-0", String(pid)], timeout: .seconds(5))
        return result.status == 0
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

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pause-acceptance-\(UUID())")
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
            let f = Self(root: root, home: home, head: head)
            let flow: [String: Any] = ["version": 1, "base": "main",
                "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
                "reviews": [String: String](), "fixed": "Fixed:",
                "moves": [["move": "fix", "when": ["no_review_or_response_newer"], "who": "author"]],
                "dispatch": ["fix": ["agent": "synthetic", "prompt": "Fix"]]]
            try JSONSerialization.data(withJSONObject: flow).write(to: f.file("flow"))
            let agent = ["/bin/sh", "-c",
                "printf '%s' \"$$\" > \"$OBSERVE/agent-pid\"; while [ -d \"$OBSERVE\" ] && [ ! -f \"$OBSERVE/release\" ]; do sleep 0.02; done"]
            var watched = WatchedRepo(slug: f.repo, path: clone)
            watched.startMoves = true
            watched.environment = ["OBSERVE": root.path]
            var config = BtonConfig(repos: [watched], pollSeconds: 60, maxAgents: 2,
                agents: ["synthetic": AgentTemplate(argv: agent)], schedules: [])
            config.codeGraphs = false
            try config.save(to: home.configURL)
            try PriceList(models: [:], updatedAt: .now).save(home: home)
            let script = """
            #!/bin/sh
            set -eu
            cd "${0%/*}"
            printf '%s\\n' "$*" >> gh-calls
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
                /usr/bin/git --git-dir=origin.git show -s --format='{"message":"%s"}' "$sha" ;;
              *) exit 2 ;;
            esac
            """
            try script.write(to: f.file("gh"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.file("gh").path)
            return f
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
