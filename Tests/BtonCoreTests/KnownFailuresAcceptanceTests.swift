@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct KnownFailuresAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func job(detail: String?, status: Job.Status = .failed, end: TimeInterval = -30) -> Job {
        var job = Job(id: UUID(),
            key: JobKey(repo: "synthetic/project", item: "schedule-7", move: "schedule", head: "synthetic-head"),
            agent: "synthetic", startedAt: now.addingTimeInterval(end - 60),
            endedAt: now.addingTimeInterval(end), status: status, detail: detail, cost: 0)
        job.flags = [.agentFailed]
        return job
    }

    @Test func aKnownFailuresHaveExactAppliedAnswersAndUnknownFailuresHaveNone() throws {
        let rows: [(String, SupervisorVerdict.Action, String)] = [
            ("waiting: codex is unavailable on this Mac; the review runs where it is installed", .none,
             "waits for a Mac that has the tool: Bton runs the move again in 30 minutes, or at once when pressed"),
            ("codex not found on this Mac's PATH", .escalate,
             "the agent's program is not on this Mac's PATH: install it or point the agent at it in Settings"),
            ("agent logged out: invalid api key", .escalate,
             "the agent needs a login on this Mac: a retry fails the same way until then"),
            ("head moved from abcdef012345 to 123456abcdef", .none,
             "the PR's head moved while the move ran: the new head gets its own move"),
            ("PR is not open: CLOSED", .none,
             "the PR closed while the move ran: nothing to retry"),
            ("checks not green: gate pending; nothing was run", .none,
             "CI is not green on this head: the move is due again when it is"),
            ("checks not trusted: the PR edits a workflow", .escalate,
             "the PR's checks cannot vouch for it (too many files, or it edits a workflow): a person merges or reviews it"),
            ("check `bash scripts/check.sh` ran 40 minutes and was stopped", .escalate,
             "a check or command ran past the move's timeoutMinutes: raise it or speed the command up, then press Retry"),
            ("environment: invalid variable name BAD-NAME", .escalate,
             "the repo's environment in Settings > Repos is invalid: fix the variable named in the detail"),
            ("check `bun run lint` exited 1", .none,
             "a check failed before the agent started: its output was posted on the PR, so the fix move gets it")
        ]
        for (detail, action, note) in rows {
            let verdict = try #require(Supervision.knownAnswer(for: job(detail: detail)), "\(detail)")
            #expect(verdict.action == action, "\(detail)")
            #expect(verdict.note == note, "\(detail)")
            #expect(verdict.applied == true, "\(detail)")
            #expect(verdict.outcome == nil, "\(detail)")
        }
        let unmatched: [String?] = [nil, "agent exited 1", "timed out", "lease lost: expired",
            "final message names no review heading", "posting the review failed: x", "checksum mismatch"]
        for detail in unmatched {
            #expect(Supervision.knownAnswer(for: job(detail: detail)) == nil)
        }
        #expect(Supervision.knownAnswer(for: job(detail: "waiting: x", status: .succeeded)) == nil)
    }

    @Test func dQuotedDetailsAreNeverKnownFailures() throws {
        let quoted = [
            "agent exited 1: codex not found on this Mac's PATH",
            "agent exited 2: check ran 40 minutes and was stopped",
            "posting the review failed: environment: x",
            "posting the review failed: codex not found on this Mac's PATH",
            "lease lost: check ran 40 minutes and was stopped",
            "decision posted: codex not found on this Mac's PATH"
        ]
        for detail in quoted {
            #expect(Supervision.knownAnswer(for: job(detail: detail)) == nil, "\(detail)")
        }
        let structured: [(String, SupervisorVerdict.Action)] = [
            ("codex not found on this Mac's PATH", .escalate),
            ("check ran 40 minutes and was stopped", .escalate),
            ("environment: x", .escalate)
        ]
        for (detail, action) in structured {
            let verdict = try #require(Supervision.knownAnswer(for: job(detail: detail)), "\(detail)")
            #expect(verdict.action == action, "\(detail)")
            #expect(verdict.applied == true, "\(detail)")
            #expect(verdict.outcome == nil, "\(detail)")
        }
    }

    @Test func eUnpostedCheckFailureIsNotAKnownAnswer() throws {
        #expect(Supervision.knownAnswer(for: job(
            detail: "posting the check failure failed: check `x` exited 1")) == nil)
        let verdict = try #require(Supervision.knownAnswer(for: job(detail: "check `x` exited 1")))
        #expect(verdict.action == SupervisorVerdict.Action.none)
    }

    private func candidate(_ jobs: [Job]) -> DispatchCandidate? {
        Supervision.candidate(settings: SupervisorSettings(enabled: true),
            agents: ["claude": AgentTemplate(argv: ["claude", "-p", "{prompt}"])], jobs: jobs,
            repo: "synthetic/project", pullRequests: [], defaultBranch: "main", me: "owner",
            now: now, log: { _ in "Synthetic diagnostic" })
    }

    @Test func bCandidateSkipsKnownAnswersAndLoggedOutJobs() throws {
        let older = job(detail: "agent exited 1", end: -60)
        let newer = job(detail: "waiting: codex is unavailable on this Mac", end: -10)
        #expect(candidate([older])?.supervises == older.id)
        for jobs in [[newer, older], [older, newer]] {
            let picked = try #require(candidate(jobs))
            #expect(picked.supervises == older.id)
        }
        let otherKnown = job(detail: "codex not found on this Mac's PATH", end: -20)
        #expect(candidate([newer, otherKnown]) == nil)
        var loggedOut = job(detail: "agent logged out: invalid api key", end: -5)
        loggedOut.flags = [.loggedOut, .repeated, .agentFailed]
        #expect(candidate([loggedOut]) == nil)
        #expect(candidate([loggedOut, older])?.supervises == older.id)
        // The flag alone also keeps a logged-out job out of supervision.
        loggedOut.detail = "agent exited 1"
        #expect(candidate([loggedOut]) == nil)
    }

    @Test func cDispatcherRecordsKnownWaitingAnswerButLeavesExitOneUnclassified() async throws {
        for exitCode in [2, 1] {
            let f = try await KnownFailuresCommandFixture.make()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let job = try await f.finished(f.start(script: "exit \(exitCode)"))
            #expect(job.status == .failed)
            if exitCode == 2 {
                #expect(job.detail?.hasPrefix("waiting: ") == true)
                let verdict = try #require(job.verdict)
                #expect(verdict.action == SupervisorVerdict.Action.none)
                #expect(verdict.applied == true)
                #expect(verdict.outcome == nil)
                #expect(f.log(job.id).contains("known failure:"))
            } else {
                #expect(job.detail?.contains("exited 1") == true)
                #expect(job.verdict == nil)
            }
        }
    }
}

private struct KnownFailuresCommandFixture {
    let base: SupervisionRunFixture
    let store: JobStore
    let dispatcher: Dispatcher
    let pr: PullRequest
    var root: URL { base.leases.root }
    var marker: URL { root.appendingPathComponent("marker") }
    var posted: String { (try? String(contentsOf: root.appendingPathComponent("posted"), encoding: .utf8)) ?? "" }
    var ghCalls: String { (try? String(contentsOf: root.appendingPathComponent("gh-seen"), encoding: .utf8)) ?? "" }

    static func make() async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        do {
            let runner = ProcessRunner()
            let pushed = try await runner.run("/usr/bin/git",
                ["-C", base.clone.path, "push", "origin", "HEAD:refs/pull/7/head"], timeout: .seconds(120))
            try #require(pushed.status == 0, "PR ref setup: \(pushed.stderr)")
            let head = try await runner.run("/usr/bin/git", ["-C", base.clone.path, "rev-parse", "HEAD"], timeout: .seconds(120))
            try #require(head.status == 0)
            let sha = String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            var pr = PullRequest(repo: base.leases.repo, number: 7, title: "Synthetic PR", author: "owner",
                authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
                headSha: sha, headRef: "feature", baseRef: "main", body: "", isDraft: false,
                labels: [], assignees: [], comments: [], updatedAt: .now)
            pr.mergeable = true
            let gh = base.leases.root.appendingPathComponent("gh")
            let original = try String(contentsOf: gh, encoding: .utf8)
            let handler = #"""
            cd "$(dirname "$0")"
            printf '%s\n' "$*" >> gh-seen
            if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
              printf '{"headRefOid":"%s","state":"OPEN"}' "$HEAD_SHA"
              exit 0
            fi
            if [ "${1-}" = pr ] && [ "${2-}" = comment ]; then
              while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" posted; shift; done
              exit 0
            fi
            if [ "${1-}" != api ]; then exit 0; fi
            """#
            try original.replacingOccurrences(of: "set -eu", with: "set -eu\nHEAD_SHA=\(sha)\n" + handler)
                .write(to: gh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
            let github = GitHubClient(ghPath: gh.path)
            let remote = base.leases.root.appendingPathComponent("origin.git").path
            let leases = try LeaseStore(home: base.home, holder: "synthetic", host: "fixture",
                github: github, remoteURL: { _ in remote })
            let store = try JobStore(home: base.home)
            return Self(base: base, store: store,
                dispatcher: Dispatcher(github: github, leases: leases, jobs: store, log: { _ in }), pr: pr)
        } catch { try? FileManager.default.removeItem(at: base.leases.root); throw error }
    }

    func start(script: String, review: Bool = true, environment: [String: String] = [:]) async throws -> UUID {
        let command = ["/bin/sh", "-c", script]
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:"]]], "fixed": "## Fixed:", "moves": [],
            "dispatch": ["review": ["command": command]]]
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
        let candidate = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: "review", owner: "owner", ownerFromRotation: false, tier: "feature", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: "review", head: pr.headSha),
            agent: nil, prompt: nil, command: command, postComment: review, timeout: .seconds(20))
        let outcome = await dispatcher.dispatch(candidate, clone: base.clone, flow: flow, agents: [:],
            environment: environment.merging(["MARKER": marker.path]) { _, new in new })
        guard case .started = outcome else { throw DispatchError.worktree("Fixture job did not start: \(outcome)") }
        return try #require(store.all().first?.id)
    }

    func log(_ id: UUID) -> String { (try? String(contentsOf: store.logURL(id), encoding: .utf8)) ?? "" }

    func finished(_ id: UUID) async throws -> Job {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline, !store.all().contains(where: { $0.id == id && $0.status != .running }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        return try #require(store.all().first { $0.id == id && $0.status != .running }, "Job must finish")
    }
}
