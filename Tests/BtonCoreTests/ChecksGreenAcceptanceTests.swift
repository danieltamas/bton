@testable import BtonCore
import Foundation
import Testing
@Suite(ProcessBound())
struct ChecksGreenAcceptanceTests {
    @Test func capturedRollupsDecode() throws {
        for (capture, state) in [(ChecksGreenFixture.success, CheckResult.State.success),
                                 (ChecksGreenFixture.failure, .failure)] {
            let pr = try ChecksGreenFixture.decoded(rollup: ChecksGreenFixture.object(capture))
            #expect(pr.checks == [CheckResult(name: "gate", state: state)])
            #expect(!pr.checksTruncated)
        }
    }
    @Test func pendingRunAndLegacyStatusDecode() throws {
        let pr = try ChecksGreenFixture.decoded(rollup: ChecksGreenFixture.rollup([
            ChecksGreenFixture.run(status: "IN_PROGRESS", conclusion: nil),
            ["__typename": "StatusContext", "context": "ci/lint", "state": "PENDING"]
        ]))
        #expect(Set(pr.checks) == Set([CheckResult(name: "gate", state: .pending),
                                     CheckResult(name: "ci/lint", state: .pending)]))
    }
    @Test(arguments: [false, true])
    func newestRerunWinsRegardlessOfArrayOrder(reversed: Bool) throws {
        let runs = [ChecksGreenFixture.run(conclusion: "FAILURE", started: "2026-10-28T10:00:00Z"),
                    ChecksGreenFixture.run(started: "2026-10-28T11:00:00Z")]
        let pr = try ChecksGreenFixture.decoded(rollup: ChecksGreenFixture.rollup(reversed ? Array(runs.reversed()) : runs))
        #expect(pr.checks == [CheckResult(name: "gate", state: .success)])
    }

    @Test func truncatedAndAbsentRollups() throws {
        let truncated = try ChecksGreenFixture.decoded(rollup: ChecksGreenFixture.rollup([ChecksGreenFixture.run()], total: 60))
        #expect(truncated.checksTruncated)
        for includeHead in [false, true] {
            let pr = try ChecksGreenFixture.decoded(rollup: NSNull(), includeHead: includeHead)
            #expect(pr.checks.isEmpty)
            #expect(!pr.checksTruncated)
        }
    }

    @Test(arguments: [false, true])
    func undatedPendingRunWinsRegardlessOfArrayOrder(reversed: Bool) throws {
        var pending = ChecksGreenFixture.run(status: "QUEUED", conclusion: nil)
        pending["startedAt"] = NSNull()
        let runs = [pending, ChecksGreenFixture.run()]
        let rollup = ChecksGreenFixture.rollup(reversed ? Array(runs.reversed()) : runs)
        let pr = try ChecksGreenFixture.decoded(rollup: rollup)
        #expect(pr.checks == [CheckResult(name: "gate", state: .pending)])
        #expect(!pr.checksTruncated)
        let decoded = try GitHubClient.decodeChecks(ChecksGreenFixture.checksAnswer(rollup))
        #expect(decoded.checks == [CheckResult(name: "gate", state: .pending)])
        #expect(!decoded.truncated)
    }

    @Test(arguments: ["success", "pending", "missing", "truncated", "workflow", "files truncated"])
    func mergeRequiresTrustedCompleteGreenChecks(scenario: String) throws {
        var pr = ChecksGreenFixture.pr()
        pr.checks = [CheckResult(name: "gate", state: .success)]
        switch scenario {
        case "pending": pr.checks = [CheckResult(name: "gate", state: .pending)]
        case "missing": pr.checks = []
        case "truncated": pr.checksTruncated = true
        case "workflow": pr.changedFiles = [".github/workflows/gate.yml"]
        case "files truncated": pr.changedFilesTruncated = true
        default: break
        }
        let move = FlowEngine.move(for: pr, flow: try ChecksGreenFixture.flow())
        #expect(move?.name == (scenario == "success" ? "merge" : nil))
    }

    @Test func redGateShowsBlockedMergeWithRuleOwner() throws {
        let pr = try ChecksGreenFixture.redPR()
        let flow = try ChecksGreenFixture.flow(["approved_current_head", "checks_green:gate"])
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "merge")
        #expect(move.owner == pr.author)
        #expect(!move.ownerFromRotation)
        #expect(move.tier == "feature")
        #expect(move.redChecks == ["gate"])
        #expect(!move.hasDispatch)
        #expect(move.labels == [])
        #expect(FlowEngine.requiredChecks(for: pr, flow: flow) == [])
    }
    @Test func pendingGateDoesNotShowBlockedMerge() throws {
        var pr = try ChecksGreenFixture.redPR()
        pr.checks = [CheckResult(name: "gate", state: .pending)]
        #expect(FlowEngine.move(for: pr, flow: try ChecksGreenFixture.mergeFlow()) == nil)
    }
    @Test func absentGateDoesNotShowBlockedMerge() throws {
        var pr = try ChecksGreenFixture.redPR()
        pr.checks = []
        #expect(FlowEngine.move(for: pr, flow: try ChecksGreenFixture.mergeFlow()) == nil)
    }
    @Test func redGateWithoutApprovalDoesNotShowBlockedMerge() throws {
        var pr = try ChecksGreenFixture.redPR()
        pr.comments = []
        #expect(FlowEngine.move(for: pr, flow: try ChecksGreenFixture.mergeFlow()) == nil)
    }
    @Test func redNamesKeepPredicateOrder() throws {
        var pr = try ChecksGreenFixture.redPR()
        pr.checks.insert(CheckResult(name: "lint", state: .failure), at: 0)
        let flow = try ChecksGreenFixture.flow(["approved_current_head", "checks_green:gate,lint"])
        #expect(FlowEngine.move(for: pr, flow: flow)?.redChecks == ["gate", "lint"])
    }
    @Test(arguments: ["checks truncated", "files truncated", "workflow"])
    func untrustedRedChecksDoNotShowBlockedMerge(scenario: String) throws {
        var pr = try ChecksGreenFixture.redPR()
        if scenario == "checks truncated" { pr.checksTruncated = true }
        if scenario == "files truncated" { pr.changedFilesTruncated = true }
        if scenario == "workflow" { pr.changedFiles = [".github/workflows/gate.yml"] }
        #expect(FlowEngine.move(for: pr, flow: try ChecksGreenFixture.mergeFlow()) == nil)
    }
    @Test func realMatchWinsOverEarlierBlockedRule() throws {
        let data = try ChecksGreenFixture.flowData(["approved_current_head", "checks_green:gate"])
        var object = try ChecksGreenFixture.object(String(decoding: data, as: UTF8.self))
        var moves = try #require(object["moves"] as? [[String: Any]])
        moves.append(["move": "ready", "when": ["approved_current_head"], "who": "author"])
        object["moves"] = moves
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
        let move = try #require(FlowEngine.move(for: ChecksGreenFixture.redPR(), flow: flow))
        #expect(move.name == "ready")
        #expect(move.redChecks == [])
    }
    @Test func blockedMergeIsNotDispatchableByItsOwner() throws {
        let pr = try ChecksGreenFixture.redPR()
        let flow = try ChecksGreenFixture.mergeFlow()
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(flow.dispatch[move.name] != nil)
        #expect(move.owner == pr.author)
        #expect(!FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: pr.author))
    }

    @Test(arguments: ["checks_green:gate,lint", "checks_green: gate , lint "])
    func everyTrimmedNameIsRequired(predicate: String) throws {
        let flow = try ChecksGreenFixture.flow([predicate])
        var pr = ChecksGreenFixture.pr()
        pr.checks = [CheckResult(name: "gate", state: .success)]
        #expect(FlowEngine.move(for: pr, flow: flow) == nil)
        pr.checks.append(CheckResult(name: "lint", state: .success))
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "merge")
        #expect(FlowEngine.requiredChecks(for: pr, flow: flow) == ["gate", "lint"])
    }

    @Test(arguments: ["checks_green", "checks_green:", "checks_green: ,"])
    func emptyCheckNamesAreInvalid(predicate: String) throws {
        guard case let .invalid(message) = Flow.load(try ChecksGreenFixture.flowData([predicate])) else {
            Issue.record("Empty checks_green must be invalid"); return
        }
        #expect(message.contains("checks_green"))
    }

    @Test func validAndUnknownPredicatesLoad() throws {
        for predicate in ["checks_green:gate", "frobnicate"] {
            guard case let .ready(flow) = Flow.load(try ChecksGreenFixture.flowData([predicate])) else {
                Issue.record("Named check and unknown predicates must load"); return
            }
            if predicate == "frobnicate" {
                #expect(FlowEngine.move(for: ChecksGreenFixture.pr(), flow: flow) == nil)
            }
        }
    }

    @Test func requiredChecksComeFromMatchingRuleInFirstAppearanceOrder() throws {
        var pr = try ChecksGreenFixture.decoded(rollup: ChecksGreenFixture.rollup([
            ChecksGreenFixture.run(), ChecksGreenFixture.run(name: "lint")]), approved: true)
        let flow = try ChecksGreenFixture.flow([
            "approved_current_head", "checks_green:gate", "checks_green:lint,gate"
        ])
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "merge")
        #expect(FlowEngine.requiredChecks(for: pr, flow: flow) == ["gate", "lint"])
        #expect(FlowEngine.requiredChecks(for: pr, flow: try ChecksGreenFixture.flow(["approved_current_head"])) == [])
        pr.checks = []
        #expect(FlowEngine.requiredChecks(for: pr, flow: flow) == [])
    }

    @Test func plannerCarriesRequiredChecks() throws {
        var pr = ChecksGreenFixture.pr()
        pr.checks = [CheckResult(name: "gate", state: .success)]
        let candidates = DispatchPlanner.candidates([pr], flow: try ChecksGreenFixture.flow(), me: pr.author, repo: pr.repo)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.requiredChecks == ["gate"])
    }

    @Test func standaloneChecksDecodeAndUnknownSHAFails() throws {
        let decoded = try GitHubClient.decodeChecks(ChecksGreenFixture.checksAnswer(ChecksGreenFixture.object(ChecksGreenFixture.success)))
        #expect(decoded.checks == [CheckResult(name: "gate", state: .success)])
        #expect(!decoded.truncated)
        #expect(throws: (any Error).self) {
            _ = try GitHubClient.decodeChecks(Data(#"{"data":{"repository":{"object":null}}}"#.utf8))
        }
        #expect(GitHubClient.checksQuery.contains("statusCheckRollup"))
    }

    @Test(arguments: ["success", "pending", "missing", "read failure", "no requirements"])
    func dispatcherReadsExactHeadBeforeCommand(scenario: String) async throws {
        let f = try await ChecksGreenDispatchFixture.make()
        defer { f.remove() }
        let rollup: [String: Any]
        switch scenario {
        case "pending": rollup = ChecksGreenFixture.rollup([ChecksGreenFixture.run(status: "IN_PROGRESS", conclusion: nil)])
        case "missing": rollup = ChecksGreenFixture.rollup([ChecksGreenFixture.run(name: "lint")])
        default: rollup = try ChecksGreenFixture.object(ChecksGreenFixture.success)
        }
        try ChecksGreenFixture.checksAnswer(rollup).write(to: f.root.appendingPathComponent("checks-answer"))
        if scenario == "read failure" { try Data().write(to: f.root.appendingPathComponent("fail-checks")) }
        let id = try await f.start(required: scenario == "no requirements" ? [] : ["gate"])
        let job = try await f.finished(id)
        let succeeds = scenario == "success" || scenario == "no requirements"
        #expect(job.status == (succeeds ? .succeeded : .failed))
        #expect(FileManager.default.fileExists(atPath: f.started.path) == succeeds)
        let calls = f.text(f.root.appendingPathComponent("checks-argv"))
        if scenario == "no requirements" {
            #expect(calls.isEmpty)
        } else {
            #expect(calls.contains("api\ngraphql\n"))
            #expect(calls.contains("oid=\(f.head)\n"))
            #expect(calls.contains("owner=synthetic\n"))
            #expect(calls.contains("name=project\n"))
        }
        let detail = job.detail ?? ""
        switch scenario {
        case "success": #expect(f.text(f.store.logURL(id)).contains("checks gate green"))
        case "pending", "missing":
            #expect(detail.hasPrefix("checks not green:"))
            #expect(detail.contains(scenario == "pending" ? "gate pending" : "gate missing"))
        case "read failure": #expect(detail.hasPrefix("could not read checks"))
        default: break
        }
        #expect(!f.text(f.root.appendingPathComponent("all-argv")).contains("pr comment"))
    }

    @Test(arguments: ["workflow", "files truncated"])
    func dispatcherRefusesUntrustedChecksDespiteGreenAnswer(scenario: String) async throws {
        let f = try await ChecksGreenDispatchFixture.make()
        defer { f.remove() }
        try ChecksGreenFixture.checksAnswer(ChecksGreenFixture.object(ChecksGreenFixture.success))
            .write(to: f.root.appendingPathComponent("checks-answer"))
        let id = try await f.start(required: ["gate"], untrusted: scenario)
        let job = try await f.finished(id)
        #expect(job.status == .failed)
        #expect((job.detail ?? "").hasPrefix("checks not trusted"))
        #expect(!FileManager.default.fileExists(atPath: f.started.path))
    }
}

private enum ChecksGreenFixture {
    // Captured lexito rollups for PRs #510 and #501, respectively.
    static let success = #"{"state":"SUCCESS","contexts":{"totalCount":1,"nodes":[{"__typename":"CheckRun","name":"gate","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-28T22:35:46Z","completedAt":"2026-10-28T22:38:35Z"}]}}"#
    static let failure = #"{"state":"FAILURE","contexts":{"totalCount":1,"nodes":[{"__typename":"CheckRun","name":"gate","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-28T17:41:01Z","completedAt":"2026-10-28T17:43:55Z"}]}}"#
    static let head = "d67db2a8" + String(repeating: "a", count: 32)

    static func object(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
    static func run(name: String = "gate", status: String = "COMPLETED", conclusion: String? = "SUCCESS",
                    started: String = "2026-10-28T11:00:00Z") -> [String: Any] {
        ["__typename": "CheckRun", "name": name, "status": status,
         "conclusion": conclusion.map { $0 as Any } ?? NSNull(), "startedAt": started]
    }
    static func rollup(_ nodes: [[String: Any]], total: Int? = nil) -> [String: Any] {
        ["contexts": ["totalCount": total ?? nodes.count, "nodes": nodes]]
    }
    static func checksAnswer(_ rollup: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": ["repository": ["object": ["statusCheckRollup": rollup]]]])
    }
    static func flowData(_ predicates: [String] = ["checks_green:gate"]) throws -> Data {
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:", "notByAuthor": true]]],
            "fixed": "## Fixed:",
            "moves": [["move": "merge", "when": predicates, "who": "author"]],
            "dispatch": ["merge": ["command": ["/usr/bin/true"]]]]
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func flow(_ predicates: [String] = ["checks_green:gate"]) throws -> Flow {
        try JSONDecoder().decode(Flow.self, from: flowData(predicates))
    }
    static func mergeFlow() throws -> Flow {
        try flow(["approved_current_head", "checks_green:gate"])
    }
    static func redPR() throws -> PullRequest {
        try decoded(rollup: object(failure), approved: true)
    }
    static func pr(head: String = head) -> PullRequest {
        PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic PR", author: "owner",
            authorAssociation: "MEMBER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: head, headRef: "feature", baseRef: "main", body: "Tier: feature", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: .now)
    }
    // Private copy of FlowFixture.graphql's node/envelope builder.
    static func decoded(rollup: Any, includeHead: Bool = true, approved: Bool = false) throws -> PullRequest {
        let comments: [[String: Any]] = approved ? [["author": ["login": "reviewer"],
            "authorAssociation": "MEMBER", "body": "## Review: approve (head d67db2a8)",
            "createdAt": "2026-10-28T12:00:00Z"]] : []
        var node: [String: Any] = [
            "number": 7, "title": "Synthetic PR", "url": "https://github.com/synthetic/project/pull/7",
            "isDraft": false, "headRefOid": head, "headRefName": "feature", "baseRefName": "main",
            "body": "Tier: feature", "updatedAt": "2026-10-28T11:00:00Z",
            "authorAssociation": "MEMBER", "author": ["login": "owner"],
            "labels": ["nodes": []], "assignees": ["nodes": []], "comments": ["nodes": comments],
            // The real query always carries `files`; without it the decoder reads "too many files", which gates close.
            "files": ["totalCount": 0, "nodes": []]
        ]
        if includeHead { node["headCommit"] = ["nodes": [["commit": ["statusCheckRollup": rollup]]]] }
        let data = try JSONSerialization.data(withJSONObject: ["data": [
            "viewer": ["login": "owner"], "repository": ["defaultBranchRef": ["name": "main"],
            "pullRequests": ["nodes": [node]]]]])
        return try #require(GitHubClient.decodeOpenPullRequests(data, repo: "synthetic/project").pullRequests.first)
    }
}

private struct ChecksGreenDispatchFixture {
    let base: SupervisionRunFixture
    let store: JobStore
    let dispatcher: Dispatcher
    let head: String
    var root: URL { base.leases.root }
    var started: URL { root.appendingPathComponent("started") }

    static func make() async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        let root = base.leases.root
        do {
            let gh = root.appendingPathComponent("gh")
            let github = GitHubClient(ghPath: gh.path)
            let remote = root.appendingPathComponent("origin.git").path
            let store = try JobStore(home: base.home)
            let leases = try LeaseStore(home: base.home, holder: "synthetic", host: "fixture", github: github, remoteURL: { _ in remote })
            let result = try await ProcessRunner().run("/usr/bin/git", ["-C", base.clone.path, "rev-parse", "HEAD"], timeout: .seconds(60))
            try #require(result.status == 0)
            let head = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let f = Self(base: base, store: store,
                dispatcher: Dispatcher(github: github, leases: leases, jobs: store, log: { _ in }), head: head)
            let pushed = try await ProcessRunner().run("/usr/bin/git",
                ["-C", base.clone.path, "push", "origin", "HEAD:refs/pull/7/head"], timeout: .seconds(60))
            try #require(pushed.status == 0)
            try "{\"headRefOid\":\"\(head)\",\"state\":\"OPEN\"}".write(
                to: root.appendingPathComponent("head-answer"), atomically: true, encoding: .utf8)
            let script = try String(contentsOf: gh, encoding: .utf8)
            let handler = #"""
            printf '%s\n' "$*" >> "${0%/*}/all-argv"
            if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
              cat "${0%/*}/head-answer"
              exit 0
            fi
            if [ "${1-}" = api ] && [ "${2-}" = graphql ]; then
              printf '%s\n' "$@" >> "${0%/*}/checks-argv"
              if [ -f "${0%/*}/fail-checks" ]; then exit 1; fi
              cat "${0%/*}/checks-answer"
              exit 0
            fi
            if [ "${1-}" != api ]; then exit 0; fi
            """#
            try script.replacingOccurrences(of: "set -eu", with: "set -eu\n" + handler)
                .write(to: gh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
            return f
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func start(required: [String], untrusted: String? = nil) async throws -> UUID {
        // Deliberately bypass the planner: only the fresh remote read can authorize this command.
        var pr = ChecksGreenFixture.pr(head: head)
        if untrusted == "workflow" { pr.changedFiles = [".github/workflows/gate.yml"] }
        if untrusted == "files truncated" { pr.changedFilesTruncated = true }
        #expect(pr.checks.isEmpty)
        var candidate = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: "merge", owner: "owner", ownerFromRotation: false, tier: "feature", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: "merge", head: head), agent: nil,
            prompt: nil, command: ["/bin/sh", "-c", "touch \"$STARTED\""], postComment: false, timeout: .seconds(60))
        candidate.requiredChecks = required
        let flow = try ChecksGreenFixture.flow()
        let before = Set(store.all().map(\.id))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while true {
            let outcome = await dispatcher.dispatch(candidate, clone: base.clone, flow: flow,
                agents: [:], environment: ["STARTED": started.path])
            switch outcome {
            case .started: return try #require(store.all().first { !before.contains($0.id) }?.id)
            case .busy where clock.now < deadline: try await Task.sleep(for: .milliseconds(20))
            default: throw DispatchError.worktree("Acceptance dispatch refused")
            }
        }
    }
    func finished(_ id: UUID) async throws -> Job {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline {
            if let job = store.all().first(where: { $0.id == id && $0.status != .running }),
               !FileManager.default.fileExists(atPath: store.lockURL(id).path) { return job }
            try await Task.sleep(for: .milliseconds(20))
        }
        await dispatcher.stop(id)
        throw DispatchError.worktree("Acceptance job exceeded sixty seconds")
    }
    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
