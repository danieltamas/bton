@testable import BtonCore
import Foundation
import Testing

struct MergeHeadPinAcceptanceTests {
    private let movedHead = "abcdef0123456789abcdef0123456789abcdef01"

    @Test func movedHeadRefusesCommand() async throws {
        let f = try await MergeHeadPinFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.setAnswer(head: movedHead)
        let id = try await f.start(checks: [], timeout: .seconds(5))
        let job = try await f.finished(id)
        #expect(job.status == .failed)
        let detail = (job.detail ?? "").lowercased()
        #expect(detail.contains("head moved"))
        #expect(detail.contains(String(f.pr.headSha.prefix(7))))
        #expect(detail.contains(String(movedHead.prefix(7))))
        #expect(!FileManager.default.fileExists(atPath: f.action.path))
        #expect(f.reads.contains("pr view 7 --repo synthetic/project --json headRefOid,state"))
    }

    @Test func headPushedDuringChecksRefusesCommand() async throws {
        let f = try await MergeHeadPinFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let replacement = f.root.appendingPathComponent("next-answer")
        try "{\"headRefOid\":\"\(movedHead)\",\"state\":\"OPEN\"}"
            .write(to: replacement, atomically: true, encoding: .utf8)
        // The answer starts OPEN at the reviewed head and changes inside a passing check.
        let check = ["/bin/sh", "-c", "sleep 0.1; cp \"$NEXT_ANSWER\" \"$HEAD_ANSWER\"; echo pushed-during-check"]
        let id = try await f.start(checks: [check], timeout: .seconds(5),
            environment: ["NEXT_ANSWER": replacement.path, "HEAD_ANSWER": f.answer.path])
        let job = try await f.finished(id)
        #expect(job.status == .failed)
        #expect((job.detail ?? "").lowercased().contains("head moved"))
        #expect((job.detail ?? "").contains(String(f.pr.headSha.prefix(7))))
        #expect((job.detail ?? "").contains(String(movedHead.prefix(7))))
        #expect(f.log(id).components(separatedBy: "\n").contains("pushed-during-check"))
        #expect(!FileManager.default.fileExists(atPath: f.action.path))
    }

    @Test(arguments: ["MERGED", "CLOSED"])
    func nonOpenPRRefusesCommand(state: String) async throws {
        let f = try await MergeHeadPinFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.setAnswer(head: f.pr.headSha, state: state)
        let id = try await f.start(checks: [], timeout: .seconds(5))
        let job = try await f.finished(id)
        #expect(job.status == .failed)
        #expect((job.detail ?? "").lowercased().contains("not open"))
        #expect(!FileManager.default.fileExists(atPath: f.action.path))
    }

    @Test(arguments: ["nonzero", "not-json", "{}", "{\"headRefOid\":null,\"state\":\"OPEN\"}",
                      "{\"headRefOid\":\"abc\"}"])
    func unreadablePRFailsClosed(answer: String) async throws {
        let f = try await MergeHeadPinFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        if answer == "nonzero" {
            try Data().write(to: f.root.appendingPathComponent("read-fails"))
        } else {
            try answer.write(to: f.answer, atomically: true, encoding: .utf8)
        }
        let id = try await f.start(checks: [], timeout: .seconds(5))
        let job = try await f.finished(id)
        #expect(job.status == .failed)
        #expect((job.detail ?? "").lowercased().contains("could not read"))
        #expect(!FileManager.default.fileExists(atPath: f.action.path))
    }

    @Test func unchangedOpenHeadRunsCommandAfterVerificationLog() async throws {
        let f = try await MergeHeadPinFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let command = ["/bin/sh", "-c", "touch \"$ACTION_FILE\""]
        let id = try await f.start(checks: [["/bin/sh", "-c", "echo checks-passed"]],
            timeout: .seconds(5), command: command)
        let job = try await f.finished(id)
        #expect(job.status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: f.action.path))
        let lines = f.log(id).components(separatedBy: "\n")
        let checked = try #require(lines.firstIndex(of: "checks-passed"))
        let verified = try #require(lines.firstIndex {
            $0.lowercased().contains("verified") && $0.contains(String(f.pr.headSha.prefix(7)))
        })
        let ran = try #require(lines.firstIndex(of: "$ " + command.joined(separator: " ")))
        #expect(checked < verified)
        #expect(verified < ran)
        #expect(f.reads.contains("pr view 7 --repo synthetic/project --json headRefOid,state"))
    }

    @Test func commandHeadPlaceholderWritesJobKeyHead() async throws {
        let f = try await MergeHeadPinFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.start(checks: [], timeout: .seconds(5),
            command: ["/bin/sh", "-c", "echo {head} > \"$ACTION_FILE\""])
        let job = try await f.finished(id)
        #expect(job.status == .succeeded)
        let written = try String(contentsOf: f.action, encoding: .utf8)
        #expect(written == job.key.head + "\n")
        #expect(job.key.head == f.pr.headSha)
    }

    @Test func agentMoveDoesNotReadPRHeadAndState() async throws {
        let f = try await MergeHeadPinFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try Data().write(to: f.root.appendingPathComponent("read-fails"))
        let id = try await f.start(checks: [], timeout: .seconds(5), agentMove: true)
        let job = try await f.finished(id)
        #expect(job.status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: f.action.path))
        #expect(f.reads.isEmpty)
    }
}

private struct MergeHeadPinFixture {
    let base: SupervisionRunFixture
    let store: JobStore
    let dispatcher: Dispatcher
    let pr: PullRequest
    var root: URL { base.leases.root }
    var action: URL { root.appendingPathComponent("action-ran") }

    static func make() async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        do {
            let runner = ProcessRunner()
            let pushed = try await runner.run("/usr/bin/git",
                ["-C", base.clone.path, "push", "origin", "HEAD:refs/pull/7/head"], timeout: .seconds(20))
            try #require(pushed.status == 0, "PR ref setup: \(pushed.stderr)")
            let head = try await runner.run("/usr/bin/git", ["-C", base.clone.path, "rev-parse", "HEAD"], timeout: .seconds(20))
            try #require(head.status == 0)
            var pr = PullRequest(repo: base.leases.repo, number: 7, title: "Synthetic PR", author: "owner",
                authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
                headSha: String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                headRef: "feature", baseRef: "main", body: "", isDraft: false,
                labels: [], assignees: [], comments: [], updatedAt: .now)
            pr.mergeable = true
            let gh = base.leases.root.appendingPathComponent("gh")
            let original = try String(contentsOf: gh, encoding: .utf8)
            let handler = #"""
            if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
              cd "$(dirname "$0")"
              printf '%s\n' "$*" >> head-reads
              [ "$*" = 'pr view 7 --repo synthetic/project --json headRefOid,state' ] || exit 91
              [ ! -f read-fails ] || exit 42
              cat head-answer
              exit 0
            fi
            if [ "${1-}" != api ]; then exit 0; fi
            """#
            try original.replacingOccurrences(of: "set -eu", with: "set -eu\n" + handler)
                .write(to: gh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
            try "{\"headRefOid\":\"\(pr.headSha)\",\"state\":\"OPEN\"}"
                .write(to: base.leases.root.appendingPathComponent("head-answer"), atomically: true, encoding: .utf8)
            let github = GitHubClient(ghPath: base.leases.root.appendingPathComponent("gh").path)
            let remote = base.leases.root.appendingPathComponent("origin.git").path
            let leases = try LeaseStore(home: base.home, holder: "synthetic", host: "fixture",
                github: github, remoteURL: { _ in remote })
            let store = try JobStore(home: base.home)
            return Self(base: base, store: store,
                dispatcher: Dispatcher(github: github, leases: leases, jobs: store, log: { _ in }), pr: pr)
        } catch { try? FileManager.default.removeItem(at: base.leases.root); throw error }
    }

    func start(checks: [[String]], timeout: Duration, agentMove: Bool = false,
               command: [String]? = nil, environment: [String: String] = [:]) async throws -> UUID {
        let move = agentMove ? "fix" : "merge"
        let actionCommand = ["/bin/sh", "-c", "touch \"$ACTION_FILE\""]
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": [String: String](), "fixed": "Fixed:", "moves": [], "dispatch": ["merge": ["command": command ?? actionCommand]],
            "checks": ["beforeSession": agentMove ? checks : [["/usr/bin/false"]],
                       "beforeMerge": agentMove ? [["/usr/bin/false"]] : checks]]
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
        let agentCandidate = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: move, owner: "owner", ownerFromRotation: false, tier: "feature", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: move, head: pr.headSha),
            agent: agentMove ? "synthetic" : nil, prompt: agentMove ? "TASK" : nil,
            command: agentMove ? nil : command ?? actionCommand, postComment: false, timeout: timeout)
        let candidate: DispatchCandidate
        if agentMove {
            candidate = agentCandidate
        } else {
            candidate = try #require(DispatchPlanner.mergeCandidate(pr, flow: flow, me: "owner", repo: pr.repo))
        }
        let outcome = await dispatcher.dispatch(candidate, clone: base.clone, flow: flow,
            agents: ["synthetic": AgentTemplate(argv: actionCommand)],
            environment: environment.merging(["ACTION_FILE": action.path]) { _, new in new })
        guard case .started = outcome else { throw DispatchError.worktree("Fixture job did not start") }
        return try #require(store.all().first?.id)
    }

    var answer: URL { root.appendingPathComponent("head-answer") }
    var reads: String {
        (try? String(contentsOf: root.appendingPathComponent("head-reads"), encoding: .utf8)) ?? ""
    }

    func setAnswer(head: String, state: String = "OPEN") throws {
        try "{\"headRefOid\":\"\(head)\",\"state\":\"\(state)\"}"
            .write(to: answer, atomically: true, encoding: .utf8)
    }

    func log(_ id: UUID) -> String {
        (try? String(contentsOf: store.logURL(id), encoding: .utf8)) ?? ""
    }

    func finished(_ id: UUID) async throws -> Job {
        let ended = try await Self.poll(for: .seconds(60)) {
            store.all().contains { $0.id == id && $0.status != .running }
        }
        if !ended {
            await dispatcher.stop(id)
            _ = try await Self.poll(for: .seconds(5)) {
                store.all().contains { $0.id == id && $0.status != .running }
            }
        }
        try #require(ended, "Job must finish within the bounded acceptance deadline")
        return try #require(store.all().first { $0.id == id })
    }

    static func poll(for duration: Duration, until condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}
