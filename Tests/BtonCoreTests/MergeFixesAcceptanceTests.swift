@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct MergeFixesAcceptanceTests {
    @Test func timeoutDetailsAndExistingFailureFlags() {
        let cases: [(String, JobFlag)] = [
            (DispatchError.timedOut("/bin/sh -c check", minutes: 10).localizedDescription, .timedOut),
            (DispatchError.timedOut("/bin/sh -c merge", minutes: 1).localizedDescription, .timedOut),
            ("timed out", .timedOut), ("bash exited 1", .failed),
            ("agent exited 1", .agentFailed), ("lease lost while renewing", .leaseLost),
            ("final message names no supervisor verdict", .noVerdict),
            ("posting the review failed: offline", .postFailed),
            ("decision posted; remove label failed", .postFailed),
            ("agent logged out", .loggedOut), ("timed out later", .failed)]
        for (detail, flag) in cases {
            #expect(Watchdog.flags(for: WatchdogFixture.job(detail: detail), among: []) == [flag])
        }
    }

    @Test func commandFactsExplainRetryHasNoRecipientEvenWithCustomPrompt() throws {
        let pr = MergeFixFixture.pr(head: "same-head")
        let job = Job(id: UUID(), key: WatchdogFixture.key, agent: nil,
            startedAt: .now.addingTimeInterval(-2), endedAt: .now, status: .failed)
        var flagged = job
        flagged.flags = [.timedOut]
        let candidate = try #require(Supervision.candidate(
            settings: SupervisorSettings(enabled: true, prompt: "CUSTOM"),
            agents: ["claude": AgentTemplate(argv: ["claude", "{prompt}"])], jobs: [flagged],
            repo: pr.repo, pullRequests: [pr], defaultBranch: "main", me: "owner", log: { _ in "LOG" }))
        let prompt = try #require(candidate.prompt)
        #expect(prompt.hasPrefix("CUSTOM"))
        for phrase in ["same commands", "no prompt", "note", "reaches no one",
                       "does not retry a command move that timed out"] {
            #expect(prompt.contains(phrase))
        }
    }

    @Test(arguments: ["command timeout", "command failure", "agent timeout", "manual timeout"])
    func engineAppliesRetryPolicyAndPersistsVerdict(mode: String) async throws {
        let f = try await MergeFixEngineFixture.make()
        defer { f.base.remove() }
        let store = try JobStore(home: f.base.home)
        let agent = mode == "agent timeout" ? "synthetic" : nil
        var flagged = Job(id: UUID(), key: JobKey(repo: f.base.repo, item: "pr-7",
            move: agent == nil ? "merge" : "fix", head: f.head), agent: agent,
            startedAt: .now.addingTimeInterval(-60), endedAt: .now.addingTimeInterval(-30),
            status: .failed, detail: mode == "command failure" ? "bash exited 1" : "timed out", cost: 0)
        flagged.flags = mode == "command failure" ? [.failed] : [.timedOut]
        try store.save(flagged)
        var supervisor = Job(id: UUID(), key: JobKey(repo: f.base.repo, item: "pr-7", move: "supervise", head: f.head),
            agent: "claude", startedAt: .now.addingTimeInterval(-20), endedAt: .now.addingTimeInterval(-10),
            status: .succeeded, cost: 0, supervises: flagged.id)
        supervisor.verdict = SupervisorVerdict(action: .retry, note: "ACCEPTANCE_NOTE")
        if mode != "manual timeout" { try store.save(supervisor) }
        let engine = try f.base.engine()
        if mode == "manual timeout" { #expect(try await engine.retry(flagged.id)) }
        let snapshot = await engine.tick()
        #expect(snapshot.problem == nil)
        let runs = snapshot.jobs.filter { $0.key == flagged.key && $0.id != flagged.id }
        let saved = try #require(store.all().first { $0.id == flagged.id })
        if mode == "command timeout" {
            #expect(runs.isEmpty)
            #expect(saved.retry == nil)
            #expect(saved.steer == nil)
            let verdict = try #require(store.all().first { $0.id == supervisor.id }?.verdict)
            #expect(verdict.applied == true)
            let outcome = try #require(verdict.outcome)
            #expect(outcome.hasPrefix("not retried"))
            for phrase in ["unchanged", "same", "limit", "timeoutMinutes", "speed up", "Retry"] {
                #expect(outcome.contains(phrase))
            }
        } else {
            #expect(runs.count == 1)
            if mode == "agent timeout" {
                #expect(runs.first?.steered == true)
                #expect(saved.steer == "ACCEPTANCE_NOTE")
            }
            if mode != "manual timeout" {
                #expect(store.all().first { $0.id == supervisor.id }?.verdict?.outcome == "retried")
                #expect(store.all().first { $0.id == supervisor.id }?.verdict?.applied == true)
            }
        }
        try await f.base.waitForJobs()
        if mode == "agent timeout" {
            #expect(try String(contentsOf: f.base.root.appendingPathComponent("prompt"), encoding: .utf8)
                .contains(Supervision.steering("ACCEPTANCE_NOTE")))
        }
        let ids = Set(store.all().filter { $0.key == flagged.key }.map(\.id))
        #expect(Set(await engine.tick().jobs.filter { $0.key == flagged.key }.map(\.id)) == ids)
        #expect(Set(try await f.base.engine().tick().jobs.filter { $0.key == flagged.key }.map(\.id)) == ids)
    }

    @Test func checkedIsOptionalForLegacyJobsAndRoundTrips() throws {
        let data = Data(#"{"id":"11111111-1111-1111-1111-111111111111","key":{"repo":"synthetic/project","item":"pr-7","move":"merge","head":"h"},"startedAt":100,"status":"failed","usage":{}}"#.utf8)
        var job = try JSONDecoder().decode(Job.self, from: data)
        #expect(job.checked == nil)
        job.checked = PassedChecks(base: "base-sha", checks: [["/bin/sh", "-c", "echo exact argv"], ["/bin/sh", "-c", "true"]])
        let decoded = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
        #expect(decoded.checked?.base == "base-sha")
        #expect(decoded.checked?.checks == job.checked?.checks)
    }

    @Test(arguments: [false, true])
    func checksAreSavedBeforeCommandOrAgentStarts(agent: Bool) async throws {
        let f = try await MergeFixFixture.make()
        defer { f.remove() }
        let checks = [["/bin/sh", "-c", "echo passed"]]
        let id = try await f.start(checks: checks, agent: agent,
            command: ["/bin/sh", "-c", "touch \"$STARTED\"; while [ ! -f \"$RELEASE\" ]; do sleep 0.02; done"])
        let started = try await MergeFixFixture.poll { FileManager.default.fileExists(atPath: f.started.path) }
        let running = f.store.all().first { $0.id == id }
        // Release before assertions so even a failed assertion cannot strand the child.
        try Data().write(to: f.release)
        #expect(started)
        #expect(running?.status == .running)
        #expect(running?.checked?.base == f.head)
        #expect(running?.checked?.checks == checks)
        #expect(try await f.finished(id).checked?.checks == checks)
    }

    /// A check that fails or times out leaves the receipts of the ones that passed before it (one
    /// receipt per check, keyed by the head tree and base tip); no check at all leaves no receipt.
    @Test(arguments: ["none", "failure", "timeout", "command timeout"])
    func incompleteChecksRecordOnlyThePassedOnes(kind: String) async throws {
        let f = try await MergeFixFixture.make()
        defer { f.remove() }
        let checks = ["none", "command timeout"].contains(kind) ? [] : [["/bin/sh", "-c", "echo first-passed"],
            ["/bin/sh", "-c", kind == "failure" ? "exit 1" : "sleep 5"]]
        let id = try await f.start(checks: checks, timeout: kind.contains("timeout") ? .seconds(1) : .seconds(60),
            command: ["/bin/sh", "-c", kind == "command timeout" ? "sleep 5; touch \"$STARTED\"" : "touch \"$STARTED\""])
        let job = try await f.finished(id)
        #expect(job.checked?.checks == (checks.isEmpty ? nil : [checks[0]]))
        #expect(job.status == (kind == "none" ? .succeeded : .failed))
        #expect(FileManager.default.fileExists(atPath: f.started.path) == (kind == "none"))
        if kind.contains("timeout") { #expect(job.flags?.contains(.timedOut) == true) }
    }

    @Test(arguments: [Job.Status.failed, .cancelled])
    func passedChecksFromUnsuccessfulMergeAreReusedAndHeadStillVerified(status: Job.Status) async throws {
        let f = try await MergeFixFixture.make()
        defer { f.remove() }
        let checks = [["/bin/sh", "-c", "echo check >> \"$COUNT\""]]
        let command = status == .cancelled
            ? ["/bin/sh", "-c", "touch \"$STARTED\"; while [ ! -f \"$RELEASE\" ]; do sleep 0.02; done"]
            : ["/bin/sh", "-c", "exit 1"]
        let firstID = try await f.start(checks: checks, command: command)
        if status == .cancelled {
            let started = try await MergeFixFixture.poll { FileManager.default.fileExists(atPath: f.started.path) }
            await f.dispatcher.stop(firstID)
            #expect(started)
            try? FileManager.default.removeItem(at: f.started)
        }
        let first = try await f.finished(firstID)
        #expect(first.status == status)
        #expect(first.checked?.checks == checks)
        #expect(try f.store.requestRetry(firstID))
        // Cached checks must not bypass the last PR-head read.
        try f.answer("different-head")
        let secondID = try await f.start(checks: checks)
        let second = try await f.finished(secondID)
        #expect(second.status == .failed)
        #expect((second.detail ?? "").lowercased().contains("head moved"))
        #expect(second.checked?.base == first.checked?.base)
        #expect(second.checked?.checks == checks)
        #expect(f.text(f.count) == "check\n")
        #expect(f.log(secondID).contains("not run again"))
        #expect(f.log(secondID).contains(firstID.uuidString))
        #expect(!FileManager.default.fileExists(atPath: f.started.path))
        #expect(try f.store.requestRetry(secondID))
        try f.answer(f.head)
        let thirdID = try await f.start(checks: checks)
        #expect(try await f.finished(thirdID).status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: f.started.path))
        #expect(f.text(f.count) == "check\n")
    }

    @Test(arguments: ["head", "repo", "item", "move", "base", "argv", "failed checks"])
    func cacheDifferencesRunEveryCheckAgain(difference: String) async throws {
        let f = try await MergeFixFixture.make()
        defer { f.remove() }
        let checks = [["/bin/sh", "-c", "echo one >> \"$COUNT\""], ["/bin/sh", "-c", "echo two >> \"$COUNT\""]]
        let key = JobKey(repo: difference == "repo" ? "other/project" : f.pr.repo,
            item: difference == "item" ? "pr-8" : "pr-7", move: difference == "move" ? "fix" : "merge",
            head: difference == "head" ? "older-head" : f.head)
        var prior = Job(id: UUID(), key: key, agent: nil, startedAt: .now.addingTimeInterval(-30),
            endedAt: .now.addingTimeInterval(-20), status: .failed, retry: true)
        if difference != "failed checks" {
            prior.checked = PassedChecks(base: difference == "base" ? "older-base" : f.head,
                checks: difference == "argv" ? Array(checks.reversed()) : checks)
        }
        try f.store.save(prior)
        let id = try await f.start(checks: checks)
        let job = try await f.finished(id)
        #expect(job.status == .succeeded)
        #expect(job.checked?.base == f.head)
        #expect(job.checked?.checks == checks)
        #expect(f.text(f.count) == "one\ntwo\n")
        #expect(!f.log(id).contains("not run again"))
    }

    @Test func movedRemoteBaseRunsAllChecksAgainAndRecordsNewTip() async throws {
        let f = try await MergeFixFixture.make()
        defer { f.remove() }
        let checks = [["/bin/sh", "-c", "echo one >> \"$COUNT\""],
                      ["/bin/sh", "-c", "echo two >> \"$COUNT\""]]
        let firstID = try await f.start(checks: checks, command: ["/bin/sh", "-c", "exit 1"])
        #expect(try await f.finished(firstID).checked?.base == f.head)
        _ = try await f.git(["-c", "user.name=Synthetic", "-c", "user.email=test@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "advance base"])
        let tip = try await f.git(["rev-parse", "HEAD"])
        _ = try await f.git(["push", "origin", "HEAD:refs/heads/main"])
        #expect(try f.store.requestRetry(firstID))
        let nextID = try await f.start(checks: checks)
        let next = try await f.finished(nextID)
        #expect(next.status == .succeeded)
        #expect(next.key.head == f.head)
        #expect(next.checked?.base == tip)
        #expect(next.checked?.checks == checks)
        #expect(f.text(f.count) == "one\ntwo\none\ntwo\n")
        #expect(!f.log(nextID).contains("not run again"))
    }

    @Test func recordsBaseBeforeChecksCanMoveItsTrackingRef() async throws {
        let f = try await MergeFixFixture.make()
        defer { f.remove() }
        _ = try await f.git(["-c", "user.name=Synthetic", "-c", "user.email=test@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "new local tip"])
        let newer = try await f.git(["rev-parse", "HEAD"])
        let check = ["/bin/sh", "-c", "git update-ref refs/remotes/origin/main \"$NEW_TIP\""]
        let id = try await f.start(checks: [check], extra: ["NEW_TIP": newer])
        #expect(try await f.finished(id).checked?.base == f.head)
    }

    @Test(arguments: ["clean", "dirty", "pruned"])
    func trustedTreeCleanupReflectsGitRegistrationAndChanges(kind: String) async throws {
        let f = try await MergeFixFixture.make()
        defer { f.remove() }
        let script: String
        switch kind {
        case "dirty": script = "echo keep > command-changes"
        case "pruned": script = "rm .git; git -C \"$CLONE\" worktree prune --expire now; echo orphan > command-changes"
        default: script = "true"
        }
        let id = try await f.start(checks: [], command: ["/bin/sh", "-c", script])
        #expect(try await f.finished(id).status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: f.trusted.path) == (kind == "dirty"))
        let kept = "kept \(f.trusted.path): the command left changes in it"
        #expect(f.log(id).contains(kept) == (kind == "dirty"))
        #expect(f.log(id).contains("kept ") == (kind == "dirty"))
        let listing = try await f.git(["worktree", "list", "--porcelain"])
        #expect(listing.contains(f.trusted.resolvingSymlinksInPath().path) == (kind == "dirty"))
    }

    @Test(arguments: [false, true])
    func orphanPreparationRequiresFresh(fresh: Bool) async throws {
        let f = try await MergeFixFixture.make()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.trusted, withIntermediateDirectories: true)
        let sentinel = f.trusted.appendingPathComponent("orphan")
        try "leftover".write(to: sentinel, atomically: true, encoding: .utf8)
        do {
            let tree = try await Worktrees.prepare(clone: f.base.clone, branch: "main", item: "base-pr-7",
                ghPath: f.gh, runner: ProcessRunner(), fresh: fresh)
            #expect(fresh)
            #expect(tree == f.trusted)
            #expect(!FileManager.default.fileExists(atPath: sentinel.path))
            #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent(".git").path))
        } catch {
            #expect(!fresh)
            #expect(error.localizedDescription.contains("is not a worktree Bton made"))
            #expect(f.text(sentinel) == "leftover")
        }
    }

    @Test(arguments: ["leaf", "parent", "clone", "outside"])
    func orphanRemovalAndFreshPreparationNeverFollowLinksOrEscapeClone(kind: String) async throws {
        let f = try await MergeFixFixture.make()
        defer { f.remove() }
        let outside = f.root.appendingPathComponent("outside")
        let target = outside.appendingPathComponent("bton-base-pr-7")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("precious")
        try "preserve".write(to: sentinel, atomically: true, encoding: .utf8)
        var clone = f.base.clone
        let path: URL
        if kind == "outside" { path = target }
        else if kind == "clone" {
            clone = f.root.appendingPathComponent("clone-link")
            try FileManager.default.createSymbolicLink(at: clone, withDestinationURL: f.base.clone)
            path = clone.appendingPathComponent(".worktrees/bton-base-pr-7")
            try FileManager.default.createDirectory(at: f.trusted, withIntermediateDirectories: true)
            try "preserve".write(to: f.trusted.appendingPathComponent("precious"), atomically: true, encoding: .utf8)
        } else {
            path = f.trusted
            if kind == "parent" {
                try FileManager.default.createSymbolicLink(at: f.base.clone.appendingPathComponent(".worktrees"), withDestinationURL: outside)
            } else {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
            }
        }
        _ = await Worktrees.removeClean(path, clone: clone, ghPath: f.gh, runner: ProcessRunner())
        #expect(f.text(sentinel) == "preserve")
        if kind == "clone" {
            #expect(!FileManager.default.fileExists(atPath: path.path))
            // Fresh preparation must also replace an orphan through the configured clone link.
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let orphan = path.appendingPathComponent("precious")
            try "replace".write(to: orphan, atomically: true, encoding: .utf8)
            let tree = try await Worktrees.prepare(clone: clone, branch: "main", item: "base-pr-7",
                ghPath: f.gh, runner: ProcessRunner(), fresh: true)
            #expect(tree.resolvingSymlinksInPath() == f.trusted.resolvingSymlinksInPath())
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent(".git").path))
            #expect(f.text(sentinel) == "preserve")
        } else if kind != "outside" {
            do {
                _ = try await Worktrees.prepare(clone: clone, branch: "main", item: "base-pr-7",
                    ghPath: f.gh, runner: ProcessRunner(), fresh: true)
            } catch { /* Refusal is allowed; following a link is not. */ }
            #expect(f.text(sentinel) == "preserve")
            #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(".git").path))
        }
    }
}

private struct MergeFixFixture {
    let base: SupervisionRunFixture
    let store: JobStore
    let dispatcher: Dispatcher
    let head: String
    var root: URL { base.leases.root }
    var gh: String { root.appendingPathComponent("gh").path }
    var pr: PullRequest { Self.pr(head: head) }
    var trusted: URL { base.clone.appendingPathComponent(".worktrees/bton-base-pr-7") }
    var count: URL { root.appendingPathComponent("check-count") }
    var started: URL { root.appendingPathComponent("started") }
    var release: URL { root.appendingPathComponent("release") }
    static func pr(head: String) -> PullRequest {
        PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic", author: "owner", authorAssociation: "OWNER",
            url: URL(string: "https://example.invalid/pr/7")!, headSha: head, headRef: "feature", baseRef: "main",
            body: "", isDraft: false, labels: [], assignees: [], comments: [], updatedAt: .now)
    }
    static func make() async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        let github = GitHubClient(ghPath: base.leases.root.appendingPathComponent("gh").path)
        let remote = base.leases.root.appendingPathComponent("origin.git").path
        let store = try JobStore(home: base.home)
        let leases = try LeaseStore(home: base.home, holder: "synthetic", host: "fixture", github: github, remoteURL: { _ in remote })
        let result = try await ProcessRunner().run("/usr/bin/git", ["-C", base.clone.path, "rev-parse", "HEAD"], timeout: .seconds(60))
        try #require(result.status == 0)
        let f = Self(base: base, store: store, dispatcher: Dispatcher(github: github, leases: leases, jobs: store, log: { _ in }),
            head: String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try await f.git(["push", "origin", "HEAD:refs/pull/7/head"])
        try f.answer(f.head)
        let script = try String(contentsOfFile: f.gh, encoding: .utf8)
        let handler = """
        if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
          cat "$(dirname "$0")/answer"
          exit 0
        fi
        if [ "${1-}" != api ]; then exit 0; fi
        """
        try script.replacingOccurrences(of: "set -eu", with: "set -eu\n" + handler).write(toFile: f.gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.gh)
        return f
    }
    func answer(_ head: String) throws {
        try "{\"headRefOid\":\"\(head)\",\"state\":\"OPEN\"}".write(to: root.appendingPathComponent("answer"), atomically: true, encoding: .utf8)
    }
    func git(_ args: [String]) async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git", ["-C", base.clone.path] + args, timeout: .seconds(60))
        try #require(result.status == 0, "Git fixture: \(result.stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func start(checks: [[String]], agent: Bool = false, timeout: Duration = .seconds(60),
               command: [String] = ["/bin/sh", "-c", "touch \"$STARTED\""], extra: [String: String] = [:]) async throws -> UUID {
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": [String: String](), "fixed": "Fixed:", "moves": [], "dispatch": [:],
            "checks": ["beforeMerge": checks, "beforeSession": checks]]
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
        let move = agent ? "fix" : "merge"
        let candidate = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: move, owner: "owner", ownerFromRotation: false, tier: "small", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: move, head: head), agent: agent ? "synthetic" : nil,
            prompt: agent ? "TASK" : nil, command: agent ? nil : command, postComment: false, timeout: timeout)
        let before = Set(store.all().map(\.id))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while true {
            let outcome = await dispatcher.dispatch(candidate, clone: base.clone, flow: flow,
                agents: ["synthetic": AgentTemplate(argv: command)], environment: extra.merging([
                    "COUNT": count.path, "STARTED": started.path, "RELEASE": release.path, "CLONE": base.clone.path]) { _, new in new })
            switch outcome {
            case .started:
                return try #require(store.all().first { !before.contains($0.id) }?.id)
            case .busy where clock.now < deadline:
                try await Task.sleep(for: .milliseconds(20))
            default:
                throw DispatchError.worktree("Acceptance dispatch refused")
            }
        }
    }
    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func log(_ id: UUID) -> String { text(store.logURL(id)) }
    func finished(_ id: UUID) async throws -> Job {
        let ended = try await Self.poll {
            store.all().contains { $0.id == id && $0.status != .running }
                && !FileManager.default.fileExists(atPath: store.lockURL(id).path)
        }
        if !ended { await dispatcher.stop(id) }
        try #require(ended, "Acceptance job exceeded sixty seconds")
        return try #require(store.all().first { $0.id == id })
    }
    static func poll(_ condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct MergeFixEngineFixture {
    let base: StartMovesFixture
    let head: String
    static func make() async throws -> Self {
        let base = try await StartMovesFixture.make()
        let clone = base.root.appendingPathComponent("clone")
        for args in [["clone", base.root.appendingPathComponent("origin.git").path, clone.path],
                     ["-C", clone.path, "-c", "user.name=Synthetic", "-c", "user.email=test@example.invalid",
                      "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Fixture"],
                     ["-C", clone.path, "push", "origin", "HEAD:refs/heads/main", "HEAD:refs/pull/7/head"]] {
            let result = try await ProcessRunner().run("/usr/bin/git", args, timeout: .seconds(60))
            try #require(result.status == 0, "Engine Git fixture: \(result.stderr)")
        }
        let result = try await ProcessRunner().run("/usr/bin/git", ["-C", clone.path, "rev-parse", "HEAD"], timeout: .seconds(60))
        let head = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try base.updatePRs(head: head)
        let gh = base.root.appendingPathComponent("gh")
        let script = try String(contentsOf: gh, encoding: .utf8)
        try script.replacingOccurrences(of: "set -eu", with: """
        set -eu
        if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
          echo '{"headRefOid":"\(head)","state":"OPEN"}'
          exit 0
        fi
        """).write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        var config = try BtonConfig.loadOrCreate(home: base.home)
        config.repos[0].path = clone.path
        config.agents = ["synthetic": AgentTemplate(argv: ["/bin/sh", "-c", "printf '%s' \"$1\" > \"$2\"", "acceptance", "{prompt}", base.root.appendingPathComponent("prompt").path])]
        try config.save(to: base.home.configURL)
        return Self(base: base, head: head)
    }
}
