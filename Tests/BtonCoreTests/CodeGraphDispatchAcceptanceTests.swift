@testable import BtonCore
import Foundation
import Testing

struct CodeGraphDispatchAcceptanceTests {
    @Test func instructionLineNamesBaseAndCommit() {
        let line = CodeGraph.instructionLine(base: "develop", marker: .init(commit: "0123456789ab", at: .now))
        #expect(line == "Code graph: graphify-out/ in this checkout is graphify's graph of develop at 01234567; this branch's own changes may not be in it. Run graphify-src \"<question>\" before searching the tree.")
    }

    @Test(ProcessBound()) func jobWorktreeGetsLinkAndClaudeGetsLine() async throws {
        let f = try await GraphDispatchFixture.make()
        defer { f.graph.remove() }
        let job = try await f.run()
        let log = (try? f.jobLog(job)) ?? ""
        #expect(job.status == .succeeded, "\(job.detail ?? "") \(log)")
        let worktree = URL(fileURLWithPath: try #require(job.worktree))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: worktree.appendingPathComponent("graphify-out").path) == f.graph.store.path)
        let prompt = try f.systemPrompt()
        let expected = "Code graph: graphify-out/ in this checkout is graphify's graph of main at \(f.graph.tip.prefix(8)); this branch's own changes may not be in it. Run graphify-src \"<question>\" before searching the tree."
        #expect(prompt.contains(expected))
        #expect(prompt.components(separatedBy: "Code graph:").count == 2)
        #expect(prompt.contains("Synthetic graph team guidance\n\n" + expected))
        #expect(try f.graph.pythonRuns() == 0)
        #expect(CodeGraph.marker(in: f.graph.store)?.commit == f.graph.tip)
        #expect(try String(contentsOf: f.graph.store.appendingPathComponent("graph.json"), encoding: .utf8) == "{\"base\":true}")
    }

    @Test(ProcessBound()) func unbuiltStoreAddsNothing() async throws {
        let f = try await GraphDispatchFixture.make(built: false)
        defer { f.graph.remove() }
        let job = try await f.run()
        let log = (try? f.jobLog(job)) ?? ""
        #expect(job.status == .succeeded, "\(job.detail ?? "") \(log)")
        let link = URL(fileURLWithPath: try #require(job.worktree)).appendingPathComponent("graphify-out")
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(try !f.systemPrompt().contains("Code graph:"))
        #expect(try f.graph.pythonRuns() == 0)
    }

    @Test(ProcessBound(), arguments: [false, true])
    func occupiedNameNeverFailsTheJob(directory: Bool) async throws {
        let f = try await GraphDispatchFixture.make(occupiedDirectory: directory)
        defer { f.graph.remove() }
        let job = try await f.run()
        let log = (try? f.jobLog(job)) ?? ""
        #expect(job.status == .succeeded, "\(job.detail ?? "") \(log)")
        let link = URL(fileURLWithPath: try #require(job.worktree)).appendingPathComponent("graphify-out")
        let content = directory ? link.appendingPathComponent("agent-owned") : link
        #expect(try String(contentsOf: content, encoding: .utf8) == "keep me")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        let notes = try f.jobLog(job).components(separatedBy: "\n").filter { $0.contains("graphify-out kept:") }
        #expect(notes.count == 1)
        #expect(try f.graph.pythonRuns() == 0)
    }

    @Test(ProcessBound()) func codexGetsNoLine() async throws {
        let f = try await GraphDispatchFixture.make(agent: "codex")
        defer { f.graph.remove() }
        let job = try await f.run()
        let log = (try? f.jobLog(job)) ?? ""
        #expect(job.status == .succeeded, "\(job.detail ?? "") \(log)")
        let link = URL(fileURLWithPath: try #require(job.worktree)).appendingPathComponent("graphify-out")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == f.graph.store.path)
        let argv = try String(contentsOf: f.graph.root.appendingPathComponent("agent-argv"), encoding: .utf8)
        #expect(!argv.contains("Code graph:"))
        #expect(!argv.contains("--append-system-prompt"))
        #expect(try f.graph.pythonRuns() == 0)
    }
}

private struct GraphDispatchFixture {
    let graph: GraphFixture
    let dispatcher: Dispatcher
    let jobs: JobStore
    let pr: PullRequest
    let agent: String

    static func make(built: Bool = true, agent: String = "claude", occupiedDirectory: Bool? = nil) async throws -> Self {
        let graph = try await GraphFixture.make(python: .succeeds)
        do {
            try "Synthetic graph team guidance".write(to: graph.clone.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
            try await GraphFixture.git(["add", "CLAUDE.md"], in: graph.clone)
            let baseTip = try await graph.commitOnOrigin("Team instructions at base")
            // A different PR head proves dispatch never substitutes a PR build for the base graph.
            try await GraphFixture.git(["checkout", "-b", "feature"], in: graph.clone)
            if let directory = occupiedDirectory {
                let link = graph.clone.appendingPathComponent("graphify-out")
                if directory { try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true) }
                let content = directory ? link.appendingPathComponent("agent-owned") : link
                try "keep me".write(to: content, atomically: true, encoding: .utf8)
                try await GraphFixture.git(["add", "graphify-out"], in: graph.clone)
            }
            try await GraphFixture.git(["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                                        "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "PR changes"], in: graph.clone)
            let head = try await GraphFixture.git(["rev-parse", "HEAD"], in: graph.clone)
            try await GraphFixture.git(["push", "origin", "HEAD:refs/pull/7/head"], in: graph.clone)
            try await GraphFixture.git(["checkout", "main"], in: graph.clone)
            // Mark the store with a deliberately older base commit, as real jobs may observe it
            // while the next base build is pending. The prompt must use the marker, not HEAD.
            #expect(baseTip != graph.tip)
            try FileManager.default.createDirectory(at: graph.store, withIntermediateDirectories: true)
            if built {
                try "{\"base\":true}".write(to: graph.store.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
            }
            try CodeGraph.writeMarker(.init(commit: graph.tip, at: Date(timeIntervalSince1970: 1)), in: graph.store)
            let executable = graph.root.appendingPathComponent(agent)
            let script = """
            #!/bin/sh
            set -eu
            printf '%s\\n' "$@" > '\(graph.root.appendingPathComponent("agent-argv").path)'
            while [ "$#" -gt 0 ]; do
              if [ "$1" = '--append-system-prompt' ]; then
                printf '%s' "$2" > '\(graph.root.appendingPathComponent("agent-system").path)'
                break
              fi
              shift
            done
            exit 0
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let github = GitHubClient(ghPath: graph.root.appendingPathComponent("gh").path)
            let remote = graph.root.appendingPathComponent("origin.git").path
            let leases = try LeaseStore(home: graph.home, holder: "synthetic", host: "fixture", github: github, remoteURL: { _ in remote })
            let jobs = try JobStore(home: graph.home)
            let dispatcher = Dispatcher(github: github, leases: leases, jobs: jobs, home: graph.home, log: { _ in })
            await dispatcher.useRepos([graph.repo])
            #expect(await dispatcher.graphStores[graph.repo.slug.lowercased()] == graph.store)
            let pr = PullRequest(repo: graph.repo.slug, number: 7, title: "Synthetic PR", author: "owner",
                authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!, headSha: head,
                headRef: "feature", baseRef: "main", body: "", isDraft: false, labels: [], assignees: [], comments: [], updatedAt: .now)
            return Self(graph: graph, dispatcher: dispatcher, jobs: jobs, pr: pr, agent: agent)
        } catch { graph.remove(); throw error }
    }

    func run() async throws -> Job {
        var candidate = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: "fix", owner: "owner", ownerFromRotation: false, tier: "feature", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: "fix", head: pr.headSha),
            agent: agent, prompt: "Synthetic task", command: nil, postComment: false, timeout: .seconds(30))
        candidate.skipsChecks = true
        let executable = graph.root.appendingPathComponent(agent).path
        let argv = agent == "codex" ? [executable, "exec", "--", "{prompt}"] : [executable, "-p", "{prompt}"]
        let outcome = await dispatcher.dispatch(candidate, clone: graph.clone, flow: nil,
            agents: [agent: AgentTemplate(argv: argv)])
        guard case .started = outcome else { throw DispatchError.worktree("Graph fixture job did not start: \(outcome)") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if let job = jobs.all().first(where: { $0.status != .running }) { return job }
            try await Task.sleep(for: .milliseconds(25))
        }
        for job in jobs.all() { await dispatcher.stop(job.id) }
        throw DispatchError.worktree("Graph fixture job did not finish")
    }

    func systemPrompt() throws -> String {
        try String(contentsOf: graph.root.appendingPathComponent("agent-system"), encoding: .utf8)
    }

    func jobLog(_ job: Job) throws -> String {
        try String(contentsOf: jobs.logURL(job.id), encoding: .utf8)
    }
}
