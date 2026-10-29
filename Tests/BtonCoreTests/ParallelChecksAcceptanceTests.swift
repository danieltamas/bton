@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct ParallelChecksAcceptanceTests {
    // a
    @Test func togetherDecodesAndRejectsMalformedAndOverlappingGroups() throws {
        let a = ["echo", "a"], b = ["echo", "b"], c = ["echo", "c"]
        let valid = try ParallelChecksFixture.flow(together: [[a, b]])
        #expect(valid.checks?.together == [[a, b]])
        let validData = try flowData(together: [[a, b]])
        guard case .ready = Flow.load(validData) else {
            Issue.record("A valid together declaration must load"); return
        }
        for group in [[[a]], [[a, []]], [[]]] {
            guard case .invalid(let message) = Flow.load(try flowData(together: group)) else {
                Issue.record("Malformed together group must be invalid"); continue
            }
            #expect(message.contains("checks.together: each group names at least two argv"))
        }
        guard case .invalid(let message) = Flow.load(try flowData(together: [[a, b], [a, c]])) else {
            Issue.record("An argv in two groups must be invalid"); return
        }
        #expect(message.contains("checks.together: echo a is in two groups"))
    }

    // b
    @Test func togetherChecksFinishClearlyFasterThanSerialChecks() async throws {
        let parallel = try await ParallelChecksFixture.make()
        defer { parallel.remove() }
        let serial = try await ParallelChecksFixture.make()
        defer { serial.remove() }
        func gates(_ f: ParallelChecksFixture) -> [[String]] {
            ["a", "b"].map { name in
                ["/bin/sh", "-c", "sleep 1.5; touch '\(f.root.appendingPathComponent(name).path)'"]
            }
        }
        let concurrentGates = gates(parallel)
        let clock = ContinuousClock()
        let concurrentStart = clock.now
        let concurrentJob = try await parallel.run(beforeSession: concurrentGates, together: [concurrentGates],
                                                    require: ["a", "b"])
        let concurrentTime = concurrentStart.duration(to: clock.now)
        let serialStart = clock.now
        let serialJob = try await serial.run(beforeSession: gates(serial), require: ["a", "b"])
        let serialTime = serialStart.duration(to: clock.now)
        #expect(concurrentJob.status == .succeeded)
        #expect(serialJob.status == .succeeded)
        #expect(serialTime >= .seconds(3))
        // Dispatch includes git and lease setup; allow load while requiring a meaningful gain.
        #expect(concurrentTime < .seconds(6))
        #expect(concurrentTime + .milliseconds(650) < serialTime)
    }

    // c
    @Test func failingCheckTerminatesSiblingAndKeepsLogBlocksTogether() async throws {
        let f = try await ParallelChecksFixture.make()
        defer { f.remove() }
        let a = ["/bin/sh", "-c", "echo a-start; sleep 0.2; echo a-end; exit 1"]
        let b = ["/bin/sh", "-c", "echo b-start; sleep 5; touch '\(f.root.appendingPathComponent("b-done").path)'; echo b-end"]
        let start = ContinuousClock.now
        let job = try await f.run(beforeSession: [a, b], together: [[a, b]])
        #expect(start.duration(to: .now) < .seconds(4))
        #expect(job.status == .failed)
        #expect(job.detail?.hasPrefix("check ") == true)
        #expect(job.detail?.contains(a.joined(separator: " ")) == true)
        #expect(!f.exists("agent-review"))
        // Observe past B's original deadline to detect an orphaned process group.
        let remaining = start.duration(to: .now)
        if remaining < .seconds(5.5) { try await Task.sleep(for: .seconds(5.5) - remaining) }
        #expect(!f.exists("b-done"))
        let log = f.text(f.store.logURL(job.id))
        let aHeader = "$ " + a.joined(separator: " ")
        let bHeader = "$ " + b.joined(separator: " ")
        #expect(log.contains(aHeader))
        #expect(log.contains(bHeader))
        let blocks = log.components(separatedBy: "$ ")
        let aBlock = try #require(blocks.first { $0.hasPrefix(a.joined(separator: " ") + "\n") })
        let bBlock = try #require(blocks.first { $0.hasPrefix(b.joined(separator: " ") + "\n") })
        #expect(aBlock.contains("\na-start\n"))
        #expect(aBlock.contains("\na-end\n"))
        #expect(!aBlock.contains("\nb-start\n"))
        #expect(bBlock.contains("\nb-start\n"))
        #expect(!bBlock.contains("\na-start\n"))
    }

    // d
    @Test func passingTogetherChecksSaveOrderedReceiptsAndAreReused() async throws {
        let f = try await ParallelChecksFixture.make()
        defer { f.remove() }
        let gates = ["a", "b"].map { ["/usr/bin/touch", f.root.appendingPathComponent($0).path] }
        let first = try await f.run(beforeSession: gates, together: [gates], require: ["a", "b"])
        #expect(first.status == .succeeded)
        #expect(first.checked?.checks == gates)
        for name in ["a", "b"] { try FileManager.default.removeItem(at: f.root.appendingPathComponent(name)) }
        let second = try await f.run(move: "fix", beforeSession: gates, together: [gates], forbid: ["a", "b"])
        #expect(second.status == .succeeded)
        #expect(first.key.head == second.key.head)
        let lines = f.text(f.store.logURL(second.id)).components(separatedBy: .newlines)
        for argv in gates {
            #expect(lines.contains { $0.contains(argv.joined(separator: " ")) && $0.contains("not run again") })
        }
        #expect(!f.exists("a"))
        #expect(!f.exists("b"))
    }

    // e
    @Test func ungroupedCheckWaitsForBothTogetherChecks() async throws {
        let f = try await ParallelChecksFixture.make()
        defer { f.remove() }
        let sequence = f.root.appendingPathComponent("sequence")
        let a = ["/bin/sh", "-c", "sleep 0.4; echo a >> '\(sequence.path)'"]
        let b = ["/bin/sh", "-c", "sleep 0.8; echo b >> '\(sequence.path)'"]
        let c = ["/bin/sh", "-c", "echo c >> '\(sequence.path)'"]
        let job = try await f.run(beforeSession: [a, b, c], together: [[a, b]])
        #expect(job.status == .succeeded)
        let entries = f.text(sequence).split(separator: "\n").map(String.init)
        #expect(entries.count == 3)
        #expect(Set(entries.prefix(2)) == Set(["a", "b"]))
        #expect(entries.last == "c")
    }

    // f
    @Test func ownGatesFillTogetherPlaceholdersAndRunAsOneGroup() async throws {
        let f = try await ParallelChecksFixture.make()
        defer { f.remove() }
        let gates = [["touch", "{head}-a"], ["touch", "{head}-b"]]
        let flow = try ParallelChecksFixture.flow(checks: gates, together: [gates])
        let candidate = try ParallelChecksFixture.candidate(ParallelChecksFixture.pr(head: f.head), flow: flow)
        let filled = gates.map { $0.map { $0.replacingOccurrences(of: "{head}", with: f.head) } }
        #expect(candidate.together == [filled])
        #expect(candidate.checks == filled)
        // The following gate checks the real worktree before Dispatcher removes it.
        let verifyMarkers = ["/bin/sh", "-c", "test -f '\(f.head)-a' && test -f '\(f.head)-b'"]
        let job = try await f.run(checks: gates + [verifyMarkers], together: [gates])
        #expect(job.status == .succeeded)
        let log = f.text(f.store.logURL(job.id))
        for argv in filled { #expect(log.contains("$ " + argv.joined(separator: " "))) }
        #expect(log.contains("ran together: 2 checks"))
    }

    private func flowData(together: [[[String]]]) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: FlowFixture.data()) as? [String: Any])
        var checks = object["checks"] as? [String: Any] ?? [:]
        checks["together"] = together
        object["checks"] = checks
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private struct ParallelChecksFixture {
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
                     beforeSession: [[String]] = [], fresh: [[String]] = [],
                     together: [[[String]]]? = nil) throws -> Flow {
        var rule: [String: Any] = ["agent": "synthetic", "prompt": "TASK", "timeoutMinutes": 1]
        if let checks { rule["checks"] = checks }
        var object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": ["small": [["heading": "## Review:"]]], "fixed": "Fixed:",
            "moves": [["move": move, "when": ["no_review_or_response_newer"], "who": "author"]],
            "dispatch": [move: rule],
            "checks": ["beforeSession": beforeSession, "beforeMerge": [], "fresh": fresh]]
        if let together {
            var gates = object["checks"] as! [String: Any]
            gates["together"] = together
            object["checks"] = gates
        }
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
             beforeSession: [[String]] = [], together: [[[String]]]? = nil,
             require present: [String] = [], forbid absent: [String] = []) async throws -> Job {
        let flow = try Self.flow(move: move, checks: checks,
            beforeSession: beforeSession, fresh: fresh, together: together)
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
