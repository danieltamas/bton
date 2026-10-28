@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct TreeReceiptsAcceptanceTests {
    private let c1 = ["/bin/sh", "-c", "echo c1 >> \"$COUNT\""]
    private let c2 = ["/bin/sh", "-c", "echo c2 >> \"$COUNT\""]

    @Test func receiptCodingAndEnvironmentFingerprint() throws {
        let fingerprint = PassedChecks.fingerprint(["B": "2", "A": "1"])
        #expect(fingerprint == PassedChecks.fingerprint(["A": "1", "B": "2"]))
        #expect(fingerprint != PassedChecks.fingerprint(["A": "2", "B": "2"]))
        #expect(fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        let receipt = PassedChecks(base: "base", checks: [c1, c2], pressed: true,
            tree: String(repeating: "a", count: 40), environment: fingerprint)
        let decoded = try JSONDecoder().decode(PassedChecks.self, from: JSONEncoder().encode(receipt))
        #expect(decoded == receipt)
        let legacy = try JSONDecoder().decode(PassedChecks.self,
            from: Data(#"{"base":"base","checks":[],"pressed":false}"#.utf8))
        #expect(legacy.tree == nil)
        #expect(legacy.environment == nil)
    }

    @Test func sameHeadAcrossAgentAndCommandMovesReusesBothChecks() async throws {
        let f = try await TreeReceiptFixture.make()
        defer { f.remove() }
        let first = try await f.run([c1, c2], agent: true)
        let second = try await f.run([c1, c2])
        #expect(first.status == .succeeded)
        #expect(second.status == .succeeded)
        #expect(f.text(f.count) == "c1\nc2\n")
        let tree = try #require(first.checked?.tree)
        let headTree = try await f.git(["rev-parse", "\(f.head)^{tree}"])
        #expect(tree.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil)
        #expect(tree == headTree)
        #expect(second.checked?.tree == tree)
        #expect(second.checked?.checks == [c1, c2])
        expectReuse(f, job: second, checks: [c1, c2], prior: first)
    }

    @Test(arguments: [false, true])
    func differentHeadReusesOnlyWhenTreeMatches(changesTree: Bool) async throws {
        let f = try await TreeReceiptFixture.make()
        defer { f.remove() }
        let first = try await f.run([c1, c2], agent: true)
        _ = try await f.git(["checkout", "-b", "second-pr"])
        let head = try await f.commit("Second PR", file: changesTree ? "new-file" : nil)
        #expect(head != f.head)
        _ = try await f.git(["push", "origin", "HEAD:refs/pull/8/head"])
        let second = try await f.run([c1, c2], item: "pr-8", head: head)
        #expect(second.status == .succeeded)
        #expect(f.text(f.count) == (changesTree ? "c1\nc2\nc1\nc2\n" : "c1\nc2\n"))
        if changesTree {
            #expect(second.checked?.tree != nil)
            #expect(second.checked?.tree != first.checked?.tree)
        } else {
            #expect(second.checked?.tree == first.checked?.tree)
            expectReuse(f, job: second, checks: [c1, c2], prior: first)
        }
    }

    @Test func partialReceiptSurvivesLaterFailureAndCoversOnlyPassedCheck() async throws {
        let f = try await TreeReceiptFixture.make()
        defer { f.remove() }
        let failing = ["/bin/sh", "-c", "echo failed >> \"$COUNT\"; exit 1"]
        let first = try await f.run([c1, failing], agent: true)
        #expect(first.status == .failed)
        #expect(first.checked?.checks == [c1])
        #expect(first.checked?.tree != nil)
        let second = try await f.run([c1, c2])
        #expect(second.status == .succeeded)
        #expect(f.text(f.count) == "c1\nfailed\nc2\n")
        #expect(second.checked?.checks == [c1, c2])
        expectReuse(f, job: second, checks: [c1], prior: first)
    }

    @Test(arguments: ["environment", "pressed", "fresh"])
    func reuseHonorsEnvironmentPressedAndFresh(boundary: String) async throws {
        let f = try await TreeReceiptFixture.make()
        defer { f.remove() }
        let first = try await f.run([c1, c2], agent: true)
        let second = try await f.run([c1, c2], pressed: boundary == "pressed",
            fresh: boundary == "fresh" ? [c2] : [],
            extra: boundary == "environment" ? ["SENTINEL": "other"] : [:])
        #expect(second.status == .succeeded)
        #expect(second.checked?.tree == first.checked?.tree)
        #expect(f.text(f.count) == (boundary == "fresh" ? "c1\nc2\nc2\n" : "c1\nc2\nc1\nc2\n"))
        if boundary == "environment" {
            #expect(second.checked?.environment != first.checked?.environment)
        }
        if boundary == "pressed" {
            #expect(first.checked?.pressed == false)
            #expect(second.checked?.pressed == true)
        }
        if boundary == "fresh" { expectReuse(f, job: second, checks: [c1], prior: first) }
    }

    @Test(arguments: [false, true])
    func legacyReceiptCoversOnlyTheSameKey(differentKey: Bool) async throws {
        let f = try await TreeReceiptFixture.make()
        defer { f.remove() }
        var prior = Job(id: UUID(), key: JobKey(repo: f.pr.repo, item: differentKey ? "pr-8" : "pr-7",
            move: "merge", head: f.head), agent: nil, startedAt: .now.addingTimeInterval(-2),
            endedAt: .now.addingTimeInterval(-1), status: .failed)
        prior.checked = PassedChecks(base: f.head, checks: [c1, c2], pressed: false)
        try f.store.save(prior)
        if !differentKey { #expect(try f.store.requestRetry(prior.id)) }
        let second = try await f.run([c1, c2])
        #expect(second.status == .succeeded)
        #expect(f.text(f.count) == (differentKey ? "c1\nc2\n" : ""))
        if !differentKey { #expect(f.log(second.id).contains("not run again")) }
    }

    @Test func movedBaseTipRerunsChecksAndPreservesHeadTree() async throws {
        let f = try await TreeReceiptFixture.make()
        defer { f.remove() }
        let first = try await f.run([c1, c2], agent: true)
        #expect(first.status == .succeeded)
        let tree = try #require(first.checked?.tree)
        _ = try await f.git(["checkout", "-B", "main", f.head])
        let tip = try await f.commit("Base advancement")
        #expect(tip != first.checked?.base)
        _ = try await f.git(["push", "origin", "HEAD:refs/heads/main"])
        let second = try await f.run([c1, c2])
        #expect(second.status == .succeeded)
        #expect(second.checked?.base == tip)
        #expect(second.checked?.tree == tree)
        #expect(f.text(f.count) == "c1\nc2\nc1\nc2\n")
    }

    private func expectReuse(_ f: TreeReceiptFixture, job: Job, checks: [[String]], prior: Job) {
        let lines = f.log(job.id).components(separatedBy: .newlines)
        for check in checks {
            #expect(lines.contains { $0.contains(check.joined(separator: " "))
                && $0.contains("not run again") && $0.contains(prior.id.uuidString)
                && $0.contains(String(prior.checked?.tree?.prefix(7) ?? "")) })
        }
    }
}

private struct TreeReceiptFixture {
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
    static func pr(head: String, number: Int = 7) -> PullRequest {
        PullRequest(repo: "synthetic/project", number: number, title: "Synthetic", author: "owner", authorAssociation: "OWNER",
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
               item: String = "pr-7", move: String? = nil, head: String? = nil,
               pressed: Bool = false, fresh: [[String]] = [],
               command: [String] = ["/bin/sh", "-c", "touch \"$STARTED\""], extra: [String: String] = [:]) async throws -> UUID {
        let selectedHead = head ?? self.head
        let selectedPR = Self.pr(head: selectedHead, number: item == "pr-8" ? 8 : 7)
        try answer(selectedHead)
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": [String: String](), "fixed": "Fixed:", "moves": [], "dispatch": [:],
            "checks": ["beforeMerge": checks, "beforeSession": checks, "fresh": fresh]]
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
        let move = move ?? (agent ? "fix" : "merge")
        var candidate = DispatchCandidate(target: .pullRequest(selectedPR),
            move: Move(name: move, owner: "owner", ownerFromRotation: false, tier: "small", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: item, move: move, head: selectedHead), agent: agent ? "synthetic" : nil,
            prompt: agent ? "TASK" : nil, command: agent ? nil : command, postComment: false, timeout: timeout)
        candidate.pressed = pressed
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
    func commit(_ message: String, file: String? = nil, contents: String = "content\n") async throws -> String {
        if let file {
            try contents.write(to: base.clone.appendingPathComponent(file), atomically: true, encoding: .utf8)
            _ = try await git(["add", file])
        }
        _ = try await git(["-c", "user.name=Synthetic", "-c", "user.email=test@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", message])
        return try await git(["rev-parse", "HEAD"])
    }
    func run(_ checks: [[String]], agent: Bool = false, item: String = "pr-7", move: String? = nil,
             head: String? = nil, pressed: Bool = false, fresh: [[String]] = [],
             extra: [String: String] = [:]) async throws -> Job {
        let id = try await start(checks: checks, agent: agent, item: item, move: move, head: head,
            pressed: pressed, fresh: fresh, extra: extra)
        return try await finished(id)
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
