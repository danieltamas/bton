@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct MoveGatesAcceptanceTests {
    // a
    @Test func decodingPreservesOwnGateOrderAndRejectsInvalidForms() throws {
        let argv = [["bun", "install", "--frozen-lockfile"], ["bun", "run", "lint"]]
        #expect(try MoveGatesFixture.flow(checks: argv).dispatch["review"]?.checks == RuleChecks.own(argv))
        #expect(try MoveGatesFixture.flow(checks: false).dispatch["review"]?.checks == RuleChecks.none)
        #expect(try MoveGatesFixture.flow(checks: true).dispatch["review"]?.checks == RuleChecks.flow)
        #expect(try MoveGatesFixture.flow().dispatch["review"]?.checks == nil)
        #expect(try MoveGatesFixture.flow(checks: [[String]]()).dispatch["review"]?.checks == RuleChecks.own([]))
        let invalidValues: [Any] = ["lint", 42, ["command": "lint"], [["ok"], "bad"]]
        for invalid in invalidValues {
            #expect(throws: DecodingError.self) { try MoveGatesFixture.flow(checks: invalid) }
        }
    }

    // b
    @Test func candidateFillsOwnGatesAndDistinguishesSkippedAndInheritedChecks() throws {
        let pr = MoveGatesFixture.pr(head: String(repeating: "b", count: 40))
        let own = try MoveGatesFixture.candidate(pr, flow: MoveGatesFixture.flow(
            checks: [["gate", "{head}", "{base}", "{repo}", "{number}", "{tier}"]]))
        #expect(own.checks == [["gate", pr.headSha, "main", pr.repo, "7", "small"]])
        #expect(!own.skipsChecks)
        let skipped = try MoveGatesFixture.candidate(pr, flow: MoveGatesFixture.flow(checks: false))
        #expect(skipped.skipsChecks)
        #expect(skipped.checks == nil)
        let inherited = try MoveGatesFixture.candidate(pr, flow: MoveGatesFixture.flow())
        #expect(inherited.checks == nil)
        #expect(!inherited.skipsChecks)
        let empty = try MoveGatesFixture.candidate(pr, flow: MoveGatesFixture.flow(checks: [[String]]()))
        #expect(empty.checks == [])
        #expect(!empty.skipsChecks)
    }

    // c
    @Test func reviewOwnGatesReplaceFlowGatesAndFixInheritsFlowGates() async throws {
        let f = try await MoveGatesFixture.make()
        defer { f.remove() }
        let review = try await f.run(checks: [f.ownGate], require: ["own-gate"], forbid: ["flow-gate"])
        #expect(review.status == .succeeded)
        #expect(f.exists("own-gate"))
        #expect(!f.exists("flow-gate"))
        #expect(f.exists("agent-review"))
        let fix = try await f.run(move: "fix", require: ["flow-gate"])
        #expect(fix.status == .succeeded)
        #expect(f.exists("flow-gate"))
        #expect(f.exists("agent-fix"))
    }

    // d
    @Test func failingOwnGatePostsFailureAndNeverSpawnsAgent() async throws {
        let f = try await MoveGatesFixture.make()
        defer { f.remove() }
        let job = try await f.run(checks: [["/bin/sh", "-c", "echo 'lint: 3 errors'; exit 1"]])
        #expect(job.status == .failed)
        #expect(job.detail?.hasPrefix("check ") == true)
        #expect(job.detail?.contains("lint: 3 errors") == true)
        let comment = f.text(f.root.appendingPathComponent("posted-comment"))
        #expect(comment.contains("lint: 3 errors"))
        #expect(comment.contains("Bton did not start `review`"))
        #expect(!f.exists("agent-review"))
        #expect(job.pid == nil)
    }

    // e
    @Test func anotherMoveReusesIdenticalArgvAndRunsOnlyNewGate() async throws {
        let f = try await MoveGatesFixture.make()
        defer { f.remove() }
        let first = try await f.run(checks: [f.ownGate], require: ["own-gate"], forbid: ["flow-gate"])
        #expect(first.status == .succeeded)
        // Removing the marker makes a second touch observable if receipt reuse regresses.
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("own-gate"))
        let newGate = ["/usr/bin/touch", f.root.appendingPathComponent("new-gate").path]
        let second = try await f.run(move: "fix", checks: [f.ownGate, newGate],
            require: ["new-gate"], forbid: ["own-gate", "flow-gate"])
        #expect(second.status == .succeeded)
        #expect(first.key.head == second.key.head)
        #expect(first.key.move != second.key.move)
        #expect(!f.exists("own-gate"))
        #expect(f.exists("new-gate"))
        #expect(!f.exists("flow-gate"))
        let log = f.text(f.store.logURL(second.id))
        #expect(log.components(separatedBy: .newlines).contains {
            $0.contains(f.ownGate.joined(separator: " ")) && $0.contains("not run again")
        })
        #expect(second.checked?.checks == [f.ownGate, newGate])
    }

    // g
    @Test func freshGateWithPlaceholderIsRunAgainAcrossMoves() async throws {
        let f = try await MoveGatesFixture.make()
        defer { f.remove() }
        let counter = f.root.appendingPathComponent("fresh-runs")
        let freshGate = ["/bin/sh", "-c", "printf '%s\\n' \"$1\" >> \"$2\"",
            "gate", "{head}", counter.path]
        let first = try await f.run(checks: [freshGate, f.ownGate], fresh: [freshGate])
        #expect(first.status == .succeeded)
        #expect(f.text(counter) == "\(f.head)\n")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("own-gate"))
        let second = try await f.run(move: "fix", checks: [freshGate, f.ownGate],
            fresh: [freshGate], require: ["fresh-runs"], forbid: ["own-gate", "flow-gate"])
        #expect(second.status == .succeeded)
        #expect(first.key.head == second.key.head)
        #expect(first.key.move != second.key.move)
        #expect(f.text(counter) == "\(f.head)\n\(f.head)\n")
        #expect(!f.exists("own-gate"))
        let lines = f.text(f.store.logURL(second.id)).components(separatedBy: .newlines)
        let filledGate = freshGate.map { $0.replacingOccurrences(of: "{head}", with: f.head) }
        #expect(!lines.contains {
            $0.contains(filledGate.joined(separator: " ")) && $0.contains("not run again")
        })
        #expect(lines.contains {
            $0.contains(f.ownGate.joined(separator: " ")) && $0.contains("not run again")
        })
    }

    // f
    @Test func teamExampleUsesOwnReviewGatesAndInheritedFixGates() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let flow = try JSONDecoder().decode(Flow.self,
            from: Data(contentsOf: package.appendingPathComponent("examples/team.flow.json")))
        let review = try #require(flow.dispatch["review"])
        guard case .own(let argv)? = review.checks else {
            Issue.record("The example review must declare its own gates")
            return
        }
        try #require(argv.count >= 2)
        #expect(argv[1] == ["bun", "install", "--frozen-lockfile"])
        #expect(try #require(flow.dispatch["fix"]).checks == nil)
        #expect(try #require(flow.dispatch["resolve"]).checks == RuleChecks.none)
    }
}

// Private copy of the tree-receipt/review dispatcher fixture, with real fake agents.
private struct MoveGatesFixture {
    let base: SupervisionRunFixture
    let store: JobStore
    let dispatcher: Dispatcher
    let head: String
    var root: URL { base.leases.root }
    var ownGate: [String] { ["/usr/bin/touch", root.appendingPathComponent("own-gate").path] }

    static func pr(head: String) -> PullRequest {
        PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: head, headRef: "feature", baseRef: "main", body: "", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: .now)
    }

    static func flow(move: String = "review", checks: Any? = nil,
                     beforeSession: [[String]] = [], fresh: [[String]] = []) throws -> Flow {
        var rule: [String: Any] = ["agent": "synthetic", "prompt": "TASK", "timeoutMinutes": 1]
        if let checks { rule["checks"] = checks }
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": ["small": [["heading": "## Review:"]]], "fixed": "Fixed:",
            "moves": [["move": move, "when": ["no_review_or_response_newer"], "who": "author"]],
            "dispatch": [move: rule],
            "checks": ["beforeSession": beforeSession, "beforeMerge": [], "fresh": fresh]]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func candidate(_ pr: PullRequest, flow: Flow) throws -> DispatchCandidate {
        try #require(DispatchPlanner.candidates([pr], flow: flow, me: "owner", repo: pr.repo).first)
    }

    static func make() async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        let root = base.leases.root
        let gh = root.appendingPathComponent("gh")
        let original = try String(contentsOf: gh, encoding: .utf8)
        let result = try await ProcessRunner().run("/usr/bin/git",
            ["-C", base.clone.path, "rev-parse", "HEAD"], timeout: .seconds(60))
        try #require(result.status == 0)
        let head = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let push = try await ProcessRunner().run("/usr/bin/git",
            ["-C", base.clone.path, "push", "origin", "HEAD:refs/pull/7/head"], timeout: .seconds(60))
        try #require(push.status == 0)
        let handler = """
        if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
          printf '%s\\n' '{"headRefOid":"\(head)","state":"OPEN"}'
          exit 0
        fi
        if [ "${1-}" = pr ] && [ "${2-}" = comment ]; then
          cp "$7" "$(dirname "$0")/posted-comment"
          exit 0
        fi
        if [ "${1-}" != api ]; then exit 0; fi
        """
        try original.replacingOccurrences(of: "set -eu", with: "set -eu\n" + handler)
            .write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let github = GitHubClient(ghPath: gh.path)
        let store = try JobStore(home: base.home)
        let remote = root.appendingPathComponent("origin.git").path
        let leases = try LeaseStore(home: base.home, holder: "synthetic", host: "fixture",
            github: github, remoteURL: { _ in remote })
        return Self(base: base, store: store,
            dispatcher: Dispatcher(github: github, leases: leases, jobs: store, log: { _ in }), head: head)
    }

    func run(move: String = "review", checks: Any? = nil, fresh: [[String]] = [],
             require present: [String] = [], forbid absent: [String] = []) async throws -> Job {
        let flow = try Self.flow(move: move, checks: checks,
            beforeSession: [["/usr/bin/touch", root.appendingPathComponent("flow-gate").path]], fresh: fresh)
        let candidate = try Self.candidate(Self.pr(head: head), flow: flow)
        let agent = root.appendingPathComponent("fake-agent-\(move)")
        // Gate markers are checked inside the agent, proving the gates run before spawn.
        let assertions = present.map { "test -f '\(root.appendingPathComponent($0).path)'" }
            + absent.map { "test ! -f '\(root.appendingPathComponent($0).path)'" }
        let script = (["#!/bin/sh", "set -eu"] + assertions
            + ["touch '\(root.appendingPathComponent("agent-\(move)").path)'", "echo done", ""]).joined(separator: "\n")
        try script.write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        let before = Set(store.all().map(\.id))
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            let outcome = await dispatcher.dispatch(candidate, clone: base.clone, flow: flow,
                agents: ["synthetic": AgentTemplate(argv: [agent.path])])
            switch outcome {
            case .started:
                let id = try #require(store.all().first { !before.contains($0.id) }?.id)
                return try await finished(id)
            case .busy:
                try await Task.sleep(for: .milliseconds(20))
            default:
                throw DispatchError.worktree("Acceptance dispatch refused: \(outcome)")
            }
        }
        throw DispatchError.worktree("Acceptance dispatch remained busy")
    }

    private func finished(_ id: UUID) async throws -> Job {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if let job = store.all().first(where: { $0.id == id && $0.status != .running }),
               !FileManager.default.fileExists(atPath: store.lockURL(id).path) { return job }
            try await Task.sleep(for: .milliseconds(20))
        }
        await dispatcher.stop(id)
        throw DispatchError.worktree("Acceptance job exceeded sixty seconds")
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
