@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct TakeoverAcceptanceTests {
    @Test(arguments: ["assigned", "rotation", "unowned"])
    func takesOnlyAssigneeMoveAndReturnsDispatchableMoveOwnedByMe(kind: String) throws {
        let flow = try TakeoverFixture.flow(reviewers: kind == "rotation" ? ["teammate"] : [])
        let pr = TakeoverFixture.pr(assignees: kind == "assigned" ? ["teammate"] : [])
        let before = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(before.owner == (kind == "unowned" ? nil : "teammate"))
        #expect(before.ownerFromRotation == (kind == "rotation"))
        let taken = try #require(FlowEngine.takeover(of: pr, flow: flow, me: "viewer"))
        #expect(taken.name == "review")
        #expect(taken.owner == "viewer")
        #expect(taken.hasDispatch)
        var reassigned = pr
        reassigned.assignees = ["viewer"]
        #expect(FlowEngine.isDispatchable(taken, pr: reassigned, flow: flow, me: "viewer"))
        #expect(pr.assignees == (kind == "assigned" ? ["teammate"] : []), "Pure evaluation preserves the input")
    }

    @Test(arguments: ["author", "teammate", "Assignee"])
    func refusesRulesWhoseTierOwnerIsNotExactlyAssignee(who: String) throws {
        let flow = try TakeoverFixture.flow(who: who)
        let pr = TakeoverFixture.pr()
        #expect(FlowEngine.move(for: pr, flow: flow)?.hasDispatch == true)
        #expect(FlowEngine.takeover(of: pr, flow: flow, me: "viewer") == nil)
    }

    @Test func usesWhoForThePRTierRatherThanAnotherTier() throws {
        let flow = try TakeoverFixture.flow(who: "author")
        #expect(FlowEngine.takeover(of: TakeoverFixture.pr(tier: "feature"), flow: flow, me: "viewer") == nil)
        let other = try #require(FlowEngine.takeover(of: TakeoverFixture.pr(tier: "small"), flow: flow, me: "viewer"))
        #expect(other.owner == "viewer")
    }

    @Test(arguments: [true, false])
    func checksTheProducingRuleEvenWhenMoveNamesRepeat(firstMatches: Bool) throws {
        var object = try #require(JSONSerialization.jsonObject(with: TakeoverFixture.flowData()) as? [String: Any])
        var rules = try #require(object["moves"] as? [[String: Any]])
        rules.insert(["move": "review", "when": firstMatches ? ["no_review_or_response_newer"] : ["draft"],
                      "who": "author"], at: 0)
        object["moves"] = rules
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
        let result = FlowEngine.takeover(of: TakeoverFixture.pr(), flow: flow, me: "viewer")
        if firstMatches { #expect(result == nil) }
        else { #expect(result?.owner == "viewer") }
    }

    @Test(arguments: ["no move", "no dispatch", "mine", "wrong base", "untrusted", "own review"])
    func refusesEachIneligibleMove(reason: String) throws {
        let flow = try TakeoverFixture.flow(dispatch: reason != "no dispatch", moves: reason != "no move")
        let pr = TakeoverFixture.pr(assignees: reason == "mine" ? ["VIEWER"] : ["teammate"],
            author: reason == "own review" ? "VIEWER" : "author",
            base: reason == "wrong base" ? "main" : "develop",
            association: reason == "untrusted" ? "CONTRIBUTOR" : "MEMBER")
        if reason != "no move" { #expect(FlowEngine.move(for: pr, flow: flow) != nil) }
        #expect(FlowEngine.takeover(of: pr, flow: flow, me: "viewer") == nil)
    }

    @Test func authorMayTakeReviewOnTierThatAllowsAuthorReview() throws {
        let move = try #require(FlowEngine.takeover(of: TakeoverFixture.pr(author: "viewer"),
            flow: TakeoverFixture.flow(notByAuthor: false), me: "viewer"))
        #expect(move.owner == "viewer")
    }

    @Test(arguments: [[], ["VIEWER"], ["teammate"], ["teammate", "ViEwEr"], ["zeta", "VIEWER", "alpha", "beta"]])
    func assignMakesExactlyOneCallAndRemovesOnlyOtherLoginsInOrder(others: [String]) async throws {
        let f = try await TakeoverFixture.make()
        defer { f.remove() }
        try await f.github.assign("viewer", replacing: others, repo: f.repo, number: 7)
        let remaining = others.filter { $0.caseInsensitiveCompare("viewer") != .orderedSame }
        let expected = f.assignArguments + (remaining.isEmpty ? [] : ["--remove-assignee", remaining.joined(separator: ",")])
        #expect(try f.calls() == [expected])
    }

    @Test(arguments: ["flow", "prs"])
    func freshReadFailureRethrowsWithoutGitHubOrLeaseWrite(read: String) async throws {
        let f = try await TakeoverFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        _ = await engine.tick(dispatching: false)
        try f.resetCalls()
        try f.text("fail-\(read)", "1")
        do {
            _ = try await engine.take(repo: f.repo, number: 7, from: "teammate")
            Issue.record("A fresh read failure must throw")
        } catch let error as GitHubClient.Failure {
            guard case let .ghFailed(status, stderr) = error else { Issue.record("Wrong read error: \(error)"); return }
            #expect(status == 41)
            #expect(stderr.contains("fresh \(read) failed"))
        } catch { Issue.record("Fresh read error was replaced: \(error)") }
        try await f.expectNoWrites(engine)
    }

    @Test(arguments: ["stale owner", "nil mismatch", "fresh nil", "missing PR", "ineligible", "changed flow"])
    func freshStateRejectsStaleRowWithChangedAndNoWrites(reason: String) async throws {
        let f = try await TakeoverFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        _ = await engine.tick(dispatching: false)
        try f.resetCalls()
        switch reason {
        case "fresh nil": try f.writePRs([TakeoverFixture.pr(assignees: [])])
        case "missing PR": try f.writePRs([])
        case "ineligible": try f.writePRs([TakeoverFixture.pr(base: "main")])
        case "changed flow": try f.writeFlow(who: "author")
        default: try f.writePRs([TakeoverFixture.pr(assignees: ["new-owner"])])
        }
        await expectTakeError(.changed) {
            _ = try await engine.take(repo: f.repo, number: 7, from: reason == "nil mismatch" ? nil : "teammate")
        }
        try await f.expectNoWrites(engine)
    }

    @Test(arguments: ["held", "unreadable"])
    func unavailableLeaseReturnsBusyWithoutChangingLeaseOrAssigning(kind: String) async throws {
        let f = try await TakeoverFixture.make()
        defer { f.remove() }
        let observer = try f.store("other-mac")
        guard case .claimed = try await observer.claim(f.item, in: f.repo) else {
            Issue.record("Fixture must hold lease first"); return
        }
        let before = try await f.ref()
        if kind == "unreadable" { try f.text("fail-lease", "1") }
        try f.resetCalls()
        let engine = try f.engine()
        await expectTakeError(.busy) { _ = try await engine.take(repo: f.repo, number: 7, from: "teammate") }
        #expect(try f.writes().isEmpty)
        #expect(try await f.ref() == before)
        #expect(await engine.tick(dispatching: false).next.isEmpty)
    }

    @Test func assignFailureReleasesLeaseRethrowsOriginalErrorAndDoesNotQueue() async throws {
        let f = try await TakeoverFixture.make()
        defer { f.remove() }
        try f.text("fail-assign", "1")
        let engine = try f.engine()
        do {
            _ = try await engine.take(repo: f.repo, number: 7, from: "teammate")
            Issue.record("Assignment failure must throw")
        } catch let error as GitHubClient.Failure {
            guard case let .ghFailed(status, stderr) = error else { Issue.record("Wrong assign error: \(error)"); return }
            #expect(status == 43)
            #expect(stderr.contains("assignment sentinel"))
        } catch { Issue.record("Assignment error was replaced: \(error)") }
        #expect(try f.writes() == [f.assignArguments + ["--remove-assignee", "teammate"]])
        try await f.expectReleased()
        #expect(await engine.tick(dispatching: false).next.isEmpty)
    }

    @Test(arguments: ["case-insensitive owner", "nil owner", "rotation owner"])
    func successAssignsUnderLeaseReleasesReturnsMoveQueuesFirstAndLogs(kind: String) async throws {
        let f = try await TakeoverFixture.make()
        defer { f.remove() }
        let unassigned = kind != "case-insensitive owner"
        try f.writePRs([TakeoverFixture.pr(assignees: unassigned ? [] : ["teammate", "second"])])
        if kind == "rotation owner" { try f.writeFlow(reviewers: ["teammate"]) }
        let engine = try f.engine()
        await engine.runNext(repo: f.repo, item: "pr-99")
        let oldOwner: String? = kind == "nil owner" ? nil : "TEAMMATE"
        let taken = try await engine.take(repo: f.repo, number: 7, from: oldOwner)
        #expect(taken.name == "review")
        #expect(taken.owner == "viewer")
        #expect(taken.hasDispatch)
        #expect(try f.writes() == [f.assignArguments + (unassigned ? [] : ["--remove-assignee", "teammate,second"])])
        #expect(try f.readText("assigned-under-lease") == "yes")
        try await f.expectReleased()
        let snapshot = await engine.tick(dispatching: false)
        // Observing the public queue avoids launching an agent. The watched repo has startMoves:false.
        #expect(snapshot.next == ["\(f.repo)#pr-7", "\(f.repo)#pr-99"])
        let calls = try f.calls()
        #expect(calls.contains { $0.contains("repos/\(f.repo)/contents/.bton/flow.json?ref=develop") })
        #expect(calls.contains { $0.starts(with: ["api", "graphql"]) })
        let lines = f.log.lines
        #expect(lines.contains { line in
            line.contains("7") && line.contains("review") && line.contains("viewer")
                && (unassigned && kind == "nil owner" || line.lowercased().contains("teammate"))
        })
    }

    @Test func takeErrorsAreDistinctEquatableAndHaveLocalizedDescriptions() {
        #expect(TakeError.changed == TakeError.changed)
        #expect(TakeError.busy == TakeError.busy)
        #expect(TakeError.changed != TakeError.busy)
        for error in [TakeError.changed, .busy] {
            let localized = error as? any LocalizedError
            #expect(localized?.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
    }
}

private func expectTakeError(_ expected: TakeError, _ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected TakeError.\(expected)") }
    catch let error as TakeError { #expect(error == expected) }
    catch { Issue.record("Expected \(expected), got \(error)") }
}

private final class TakeoverLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.lock(); defer { lock.unlock() }; storage.append(line) }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct TakeoverFixture {
    let root: URL
    let home: BtonHome
    let log = TakeoverLog()
    let repo = "synthetic/project"
    var item: LeaseItem { LeaseItem("pr-7")! }
    var github: GitHubClient { GitHubClient(ghPath: root.appendingPathComponent("gh").path) }
    var assignArguments: [String] { ["pr", "edit", "7", "--repo", repo, "--add-assignee", "viewer"] }

    static func flow(who: String = "assignee", reviewers: [String] = [], dispatch: Bool = true,
                     moves: Bool = true, notByAuthor: Bool = true) throws -> Flow {
        try JSONDecoder().decode(Flow.self, from: flowData(who: who, reviewers: reviewers,
            dispatch: dispatch, moves: moves, notByAuthor: notByAuthor))
    }

    static func flowData(who: String = "assignee", reviewers: [String] = [], dispatch: Bool = true,
                         moves: Bool = true, notByAuthor: Bool = true) throws -> Data {
        let object: [String: Any] = ["version": 1, "base": "develop",
            "tier": ["marker": "Tier:", "values": ["feature", "small"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:", "notByAuthor": notByAuthor]]],
            "fixed": "## Fixed:", "reviewers": reviewers,
            "moves": moves ? [["move": "review", "when": ["no_review_or_response_newer"],
                                "who": ["feature": who, "small": "assignee"]]] : [],
            "dispatch": dispatch ? ["review": ["agent": "synthetic", "prompt": "Review"]] : [:]]
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func pr(assignees: [String] = ["teammate"], author: String = "author", base: String = "develop",
                   association: String = "MEMBER", tier: String = "feature") -> PullRequest {
        PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic PR", author: author,
            authorAssociation: association, url: URL(string: "https://example.invalid/pr/7")!,
            headSha: String(repeating: "a", count: 40), headRef: "feature", baseRef: base,
            body: "Tier: \(tier)", isDraft: false, labels: [], assignees: assignees, comments: [],
            updatedAt: Date(timeIntervalSince1970: 1_792_411_200))
    }

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-takeover-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("engine").path])
        let f = Self(root: root, home: home)
        do {
            try home.prepare()
            let remote = root.appendingPathComponent("origin.git").path
            let bare = home.url.appendingPathComponent("leases.git").path
            for args in [["init", "--bare", remote], ["init", "--bare", bare],
                         ["-C", bare, "hash-object", "-w", "-t", "tree", "/dev/null"],
                         ["-C", bare, "config", "url.\(remote).insteadOf", "https://github.com/\(f.repo).git"]] {
                _ = try await f.git(args)
            }
            var watched = WatchedRepo(slug: f.repo, path: root.path)
            watched.branch = "develop"
            watched.startMoves = false
            #expect(!watched.startsMoves)
            try BtonConfig(repos: [watched], pollSeconds: 60, maxAgents: 0, agents: [:], schedules: [])
                .save(to: home.configURL)
            try f.writeFlow()
            try f.writePRs([pr()])
            try f.installGH()
            return f
        } catch { f.remove(); throw error }
    }

    func engine() throws -> Engine {
        try text("require-lease", "1")
        return try Engine(home: home, github: github, log: { [log] in log.append($0) })
    }
    func store(_ holder: String) throws -> LeaseStore {
        let remote = root.appendingPathComponent("origin.git").path
        return try LeaseStore(home: BtonHome(environment: ["BTON_HOME": root.appendingPathComponent(holder).path]),
            holder: holder, host: holder, github: github, remoteURL: { _ in remote })
    }
    func text(_ name: String, _ value: String) throws {
        try value.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func readText(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    func writeFlow(who: String = "assignee", reviewers: [String] = []) throws {
        try Self.flowData(who: who, reviewers: reviewers).write(to: root.appendingPathComponent("flow"))
    }
    func writePRs(_ prs: [PullRequest]) throws {
        let nodes: [[String: Any]] = prs.map { pr in
            ["number": pr.number, "title": pr.title, "url": pr.url.absoluteString, "isDraft": pr.isDraft,
             "headRefOid": pr.headSha, "headRefName": pr.headRef, "baseRefName": pr.baseRef,
             "body": pr.body, "updatedAt": "2026-10-26T12:00:00Z", "authorAssociation": pr.authorAssociation,
             "author": ["login": pr.author], "labels": ["nodes": []],
             "assignees": ["nodes": pr.assignees.map { ["login": $0] }], "comments": ["nodes": []]]
        }
        let object: [String: Any] = ["data": ["viewer": ["login": "viewer"], "repository": [
            "defaultBranchRef": ["name": "main"], "pullRequests": ["nodes": nodes,
                "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]]]]
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("prs"))
    }

    func installGH() throws {
        let script = #"""
        #!/bin/bash
        set -eu
        cd "${0%/*}"
        printf '%s\0' "$@" >> argv
        printf '\0' >> argv
        if [ "${1-}" = pr ] && [ "${2-}" = edit ]; then
          if [ -f require-lease ]; then
            message=$(/usr/bin/git --git-dir=origin.git show -s --format=%s refs/bton/leases/pr-7)
            case "$message" in *'"released":false'*) printf yes > assigned-under-lease ;; *) exit 91 ;; esac
          fi
          if [ -f fail-assign ]; then echo 'assignment sentinel' >&2; exit 43; fi
          exit 0
        fi
        case "${2-}" in
          repos/synthetic/project/contents/.bton/flow.json?ref=develop)
            if [ -f fail-flow ]; then echo 'fresh flow failed' >&2; exit 41; fi
            cat flow ;;
          graphql)
            if [ -f fail-prs ]; then echo 'fresh prs failed' >&2; exit 41; fi
            cat prs ;;
          user) echo viewer ;;
          repos/synthetic/project/git/ref/*)
            if [ -f fail-lease ]; then echo 'lease offline' >&2; exit 42; fi
            ref="refs/${2#repos/synthetic/project/git/ref/}"
            if sha=$(/usr/bin/git --git-dir=origin.git rev-parse --verify "$ref" 2>/dev/null); then
              printf '{"object":{"sha":"%s"}}' "$sha"
            else echo 'HTTP 404' >&2; exit 1; fi ;;
          repos/synthetic/project/git/commits/*)
            message=$(/usr/bin/git --git-dir=origin.git show -s --format=%s "${2##*/}")
            message=${message//\\/\\\\}
            message=${message//\"/\\\"}
            printf '{"message":"%s"}' "$message" ;;
          list) echo '[]' ;;
          *) echo 'unexpected gh call' >&2; exit 97 ;;
        esac
        """#
        try text("gh", script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("gh").path)
    }

    func calls() throws -> [[String]] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("argv").path) else { return [] }
        let bytes = try Data(contentsOf: root.appendingPathComponent("argv"))
        var calls: [[String]] = [], current: [String] = []
        for arg in bytes.split(separator: 0, omittingEmptySubsequences: false).dropLast() {
            if arg.isEmpty { calls.append(current); current = [] }
            else { current.append(String(decoding: arg, as: UTF8.self)) }
        }
        return calls
    }
    func writes() throws -> [[String]] { try calls().filter { $0.first != "api" || $0.contains("--method") || $0.contains("-X") } }
    func resetCalls() throws { try Data().write(to: root.appendingPathComponent("argv")) }
    func git(_ args: [String]) async throws -> ProcessOutput {
        let result = try await ProcessRunner().run("/usr/bin/git", args,
            environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], timeout: .seconds(120))
        try #require(result.status == 0, "Local Git fixture: \(result.stderr)")
        return result
    }
    func ref() async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git", ["--git-dir=\(root.appendingPathComponent("origin.git").path)",
            "rev-parse", "--verify", "refs/bton/leases/pr-7"], timeout: .seconds(120))
        return result.status == 0 ? String(decoding: result.stdout, as: UTF8.self) : "absent"
    }
    func expectNoWrites(_ engine: Engine) async throws {
        #expect(try writes().isEmpty)
        #expect(try await ref() == "absent")
        #expect(await engine.tick(dispatching: false).next.isEmpty)
    }
    func expectReleased() async throws {
        guard case let .free(record) = try await store("observer").state(of: item, in: repo) else {
            Issue.record("Take must release the PR lease"); return
        }
        #expect(record.released)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
